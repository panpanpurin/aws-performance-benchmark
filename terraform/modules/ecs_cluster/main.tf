data "aws_iam_policy_document" "ecs_instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance" {
  name               = "${var.name}-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.ecs_instance_assume.json
  description        = "ECS container instance role"

  tags = merge(var.tags, {
    Name      = "${var.name}-ecs-instance"
    Component = "iam"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.name}-ecs-instance"
  role = aws_iam_role.ecs_instance.name

  tags = merge(var.tags, {
    Name      = "${var.name}-ecs-instance"
    Component = "iam"
  })
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-cluster"
    Component = "ecs"
  })
}

locals {
  ecs_ami = var.ami_id
}

resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.name}-ecs-"
  image_id      = local.ecs_ami
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  vpc_security_group_ids = var.ecs_instance_security_group_ids

  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.this.name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_CONTAINER_METADATA=true >> /etc/ecs/ecs.config
  EOT
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name      = "${var.name}-ecs-instance"
      Component = "ecs"
    })
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-ecs-lt"
    Component = "ecs"
  })
}

resource "aws_autoscaling_group" "ecs" {
  name                      = "${var.name}-ecs-asg"
  vpc_zone_identifier       = var.private_subnet_ids
  min_size                  = var.asg_min
  max_size                  = var.asg_max
  desired_capacity          = var.asg_desired
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-ecs-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "ec2" {
  # ECS rejects names prefixed with "aws", "ecs", or "fargate"
  name = "${replace(var.name, "aws-", "")}-ec2-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-ec2-cp"
    Component = "ecs"
  })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = [aws_ecs_capacity_provider.ec2.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 1
    base              = 0
  }
}

resource "aws_ecs_task_definition" "app" {
  for_each = var.apps

  family                   = "${var.name}-${each.value.name}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = each.value.needs_rds ? var.task_role_arn : null

  container_definitions = jsonencode([
    merge(
      {
        name      = each.value.name
        image     = var.image_refs[each.key]
        essential = true
        cpu       = var.task_cpu
        memory    = var.task_memory
        portMappings = [
          {
            containerPort = each.value.port
            hostPort      = each.value.port
            protocol      = "tcp"
          }
        ]
        environment = concat(
          [
            { name = "PORT", value = tostring(each.value.port) },
            { name = "NODE_ENV", value = "production" },
          ],
          each.value.needs_rds ? [
            { name = "DB_SCHEMA", value = coalesce(try(each.value.db_schema_ecs, null), "ecs") },
            { name = "DB_SSL", value = "true" },
          ] : []
        )
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = "/ecs/${each.value.name}"
            "awslogs-region"        = var.aws_region
            "awslogs-stream-prefix" = "ecs"
          }
        }
      },
      each.value.needs_rds && var.db_secret_arn != "" ? {
        secrets = [
          {
            name      = "DB_HOST"
            valueFrom = "${var.db_secret_arn}:host::"
          },
          {
            name      = "DB_PORT"
            valueFrom = "${var.db_secret_arn}:port::"
          },
          {
            name      = "DB_NAME"
            valueFrom = "${var.db_secret_arn}:dbname::"
          },
          {
            name      = "DB_USER"
            valueFrom = "${var.db_secret_arn}:username::"
          },
          {
            name      = "DB_PASSWORD"
            valueFrom = "${var.db_secret_arn}:password::"
          },
          {
            name      = "JWT_SECRET"
            valueFrom = "${var.jwt_secret_arn}:JWT_SECRET::"
          },
        ]
      } : {}
    )
  ])

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.value.name}"
    App       = each.key
    Component = "ecs"
  })
}

resource "aws_ecs_service" "app" {
  for_each = var.apps

  name            = each.value.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app[each.key].arn
  desired_count   = var.service_desired_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.task_security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arns[each.key]
    container_name   = each.value.name
    container_port   = each.value.port
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.value.name}"
    App       = each.key
    Component = "ecs"
  })

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}
