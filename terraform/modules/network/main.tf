data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  public_subnet_cidrs = [
    for i, az in local.azs : cidrsubnet(var.cidr_block, 4, i)
  ]
  private_subnet_cidrs = [
    for i, az in local.azs : cidrsubnet(var.cidr_block, 4, i + 8)
  ]
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name      = "${var.name}-vpc"
    Component = "network"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name      = "${var.name}-igw"
    Component = "network"
  })
}

resource "aws_subnet" "public" {
  for_each = {
    for i, az in local.azs : az => {
      az   = az
      cidr = local.public_subnet_cidrs[i]
      idx  = i
    }
  }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name      = "${var.name}-public-${each.value.idx}"
    Tier      = "public"
    Component = "network"
  })
}

resource "aws_subnet" "private" {
  for_each = {
    for i, az in local.azs : az => {
      az   = az
      cidr = local.private_subnet_cidrs[i]
      idx  = i
    }
  }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr

  tags = merge(var.tags, {
    Name      = "${var.name}-private-${each.value.idx}"
    Tier      = "private"
    Component = "network"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name      = "${var.name}-public-rt"
    Component = "network"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name      = "${var.name}-nat-eip"
    Component = "network"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = values(aws_subnet.public)[0].id

  tags = merge(var.tags, {
    Name      = "${var.name}-nat"
    Component = "network"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name      = "${var.name}-private-rt"
    Component = "network"
  })
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Gateway endpoints are free. ECR serves image layers from S3, so every instance
# and task pull would otherwise be billed as NAT data processing and be slower.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, {
    Name      = "${var.name}-s3"
    Component = "network"
  })
}
