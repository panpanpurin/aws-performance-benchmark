# In-region Artillery load generator.
#
# Load is generated in-region because a workstation uplink cannot supply the
# measured phase rates: the three suites together need ~26 Mbps at 2 req/s each
# and ~360 Mbps at the steady rate. A saturated generator is shared by all three
# platforms and degrades them unevenly.
#
# Public subnet, so traffic reaches the internet-facing ALB over the AWS edge
# rather than through the NAT gateway the apps share.

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-loadgen-${var.account_id}"
  force_destroy = true

  tags = merge(var.tags, {
    Name      = "${var.name}-loadgen"
    Component = "loadgen"
  })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "loadgen" {
  name = "${var.name}-loadgen"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Component = "loadgen" })
}

resource "aws_iam_role_policy_attachment" "loadgen_ssm" {
  role       = aws_iam_role.loadgen.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "loadgen" {
  statement {
    sid    = "ArtifactsReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "loadgen" {
  name   = "${var.name}-loadgen"
  role   = aws_iam_role.loadgen.id
  policy = data.aws_iam_policy_document.loadgen.json
}

resource "aws_iam_instance_profile" "loadgen" {
  name = "${var.name}-loadgen"
  role = aws_iam_role.loadgen.name
}

resource "aws_security_group" "loadgen" {
  name        = "${var.name}-loadgen"
  description = "Artillery load generator; egress only, reached via SSM"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name}-loadgen"
    Component = "loadgen"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# No ingress: SSM works over an outbound connection.
resource "aws_vpc_security_group_egress_rule" "loadgen_all" {
  security_group_id = aws_security_group.loadgen.id
  description       = "Egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, {
    Name      = "${var.name}-loadgen-egress"
    Component = "loadgen"
  })
}

resource "aws_instance" "loadgen" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.loadgen.id]
  iam_instance_profile        = aws_iam_instance_profile.loadgen.name
  associate_public_ip_address = true

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    artillery_version = var.artillery_version
    form_data_version = var.form_data_version
    bucket            = aws_s3_bucket.artifacts.bucket
    aws_region        = var.aws_region
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-loadgen"
    Component = "loadgen"
  })
}
