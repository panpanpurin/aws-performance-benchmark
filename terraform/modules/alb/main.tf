resource "aws_lb" "this" {
  name               = substr(replace("${var.name}-apps", "_", "-"), 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.subnet_ids

  enable_deletion_protection = false
  idle_timeout               = 60

  tags = merge(var.tags, {
    Name      = "${var.name}-apps"
    Component = "alb"
  })
}

resource "aws_lb_target_group" "ec2" {
  for_each = var.apps

  name        = substr(replace("${var.name}-${each.key}-ec2", "_", "-"), 0, 32)
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = each.value.health_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-ec2"
    App       = each.key
    Platform  = "ec2"
    Component = "alb"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "ecs" {
  for_each = var.apps

  name        = substr(replace("${var.name}-${each.key}-ecs", "_", "-"), 0, 32)
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = each.value.health_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-ecs"
    App       = each.key
    Platform  = "ecs"
    Component = "alb"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.certificate_arn != "" ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.certificate_arn == "" ? [1] : []
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "ok"
        status_code  = "200"
      }
    }
  }

  tags = merge(var.tags, {
    Component = "alb"
  })
}

resource "aws_lb_listener_rule" "http_ec2" {
  for_each = var.certificate_arn == "" ? {
    for k, a in var.apps : k => a if a.host_ec2 != ""
  } : {}

  listener_arn = aws_lb_listener.http.arn
  priority     = 10 + index(keys(var.apps), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host_ec2]
    }
  }
}

resource "aws_lb_listener_rule" "http_ecs" {
  for_each = var.certificate_arn == "" ? {
    for k, a in var.apps : k => a if a.host_ecs != ""
  } : {}

  listener_arn = aws_lb_listener.http.arn
  priority     = 40 + index(keys(var.apps), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host_ecs]
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }

  tags = merge(var.tags, {
    Component = "alb"
  })
}

resource "aws_lb_listener_rule" "https_ec2" {
  for_each = var.certificate_arn != "" ? {
    for k, a in var.apps : k => a if a.host_ec2 != ""
  } : {}

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10 + index(keys(var.apps), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host_ec2]
    }
  }
}

resource "aws_lb_listener_rule" "https_ecs" {
  for_each = var.certificate_arn != "" ? {
    for k, a in var.apps : k => a if a.host_ecs != ""
  } : {}

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 40 + index(keys(var.apps), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host_ecs]
    }
  }
}
