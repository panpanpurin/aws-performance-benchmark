resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB public HTTPS/HTTP"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name}-alb"
    Component = "security"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "ec2" {
  name        = "${var.name}-ec2-apps"
  description = "EC2 apps; ingress from ALB only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name}-ec2-apps"
    Component = "security"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  for_each = var.app_ports

  security_group_id            = aws_security_group.ec2.id
  description                  = "ALB to EC2 ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "ec2_all" {
  security_group_id = aws_security_group.ec2.id
  description       = "Egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "ecs" {
  name        = "${var.name}-ecs-tasks"
  description = "ECS tasks; ingress from ALB only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name}-ecs-tasks"
    Component = "security"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  for_each = var.app_ports

  security_group_id            = aws_security_group.ecs.id
  description                  = "ALB to ECS ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "ecs_all" {
  security_group_id = aws_security_group.ecs.id
  description       = "Egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "lambda" {
  name        = "${var.name}-lambda"
  description = "Lambda ENIs; egress only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name}-lambda"
    Component = "security"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "lambda_all" {
  security_group_id = aws_security_group.lambda.id
  description       = "Egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "Postgres; 5432 from app SGs"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name}-rds"
    Component = "security"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ec2" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from EC2"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.ec2.id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from ECS"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.ecs.id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from Lambda"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.lambda.id
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id
  description       = "Egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "ecs_instances" {
  name        = "${var.name}-ecs-instances"
  description = "ECS container instances"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name      = "${var.name}-ecs-instances"
    Component = "security"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "ecs_instances_all" {
  security_group_id = aws_security_group.ecs_instances.id
  description       = "Egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
