locals {
  subnet_list = var.subnet_ids
  app_keys    = keys(var.apps)
}

resource "aws_instance" "app" {
  for_each = var.apps

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_list[index(local.app_keys, each.key) % length(local.subnet_list)]
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile_name

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    app_name            = each.value.name
    app_port            = each.value.port
    image_ref           = try(var.image_refs[each.key], "")
    aws_region          = var.aws_region
    needs_rds           = each.value.needs_rds
    db_secret_arn       = var.db_secret_arn
    jwt_secret_arn      = var.jwt_secret_arn
    db_schema           = "ec2"
    container_cpus      = var.container_cpus
    container_memory_mb = var.container_memory_mb
  }))

  # Burstable families only. t2 defaults to standard and t3/t4g default to
  # unlimited, so leaving this unset would let ECS burst past its baseline
  # while EC2 throttles. Non-burstable types reject the argument, hence the
  # conditional.
  dynamic "credit_specification" {
    for_each = can(regex("^t[234]", var.instance_type)) ? [1] : []
    content {
      cpu_credits = var.cpu_credits
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.value.name}-ec2"
    App       = each.key
    Platform  = "ec2"
    Component = "ec2"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_lb_target_group_attachment" "app" {
  for_each = {
    for k, a in var.apps : k => a if contains(keys(var.target_group_arns), k)
  }

  target_group_arn = var.target_group_arns[each.key]
  target_id        = aws_instance.app[each.key].id
  port             = each.value.port
}
