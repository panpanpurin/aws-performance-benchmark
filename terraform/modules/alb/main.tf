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

  # Tolerant on purpose. The health check must not be able to deregister a
  # target that is merely slow: during the stress phase a saturated 1-vCPU
  # event loop can queue /health past a short timeout, and ECS replaces a task
  # its target group reports unhealthy. That would reset the container mid-run,
  # lose its accumulated CPU and RAM peaks, and cannot happen to Lambda.
  #
  # interval stays at 30s so a fresh target still goes healthy in ~60s, but
  # deregistration now needs 10 consecutive failures, i.e. 5 minutes - longer
  # than any single load phase.
  health_check {
    enabled             = true
    path                = each.value.health_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 20
    healthy_threshold   = 2
    unhealthy_threshold = 10
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

  # Tolerant on purpose. The health check must not be able to deregister a
  # target that is merely slow: during the stress phase a saturated 1-vCPU
  # event loop can queue /health past a short timeout, and ECS replaces a task
  # its target group reports unhealthy. That would reset the container mid-run,
  # lose its accumulated CPU and RAM peaks, and cannot happen to Lambda.
  #
  # interval stays at 30s so a fresh target still goes healthy in ~60s, but
  # deregistration now needs 10 consecutive failures, i.e. 5 minutes - longer
  # than any single load phase.
  health_check {
    enabled             = true
    path                = each.value.health_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 20
    healthy_threshold   = 2
    unhealthy_threshold = 10
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
    for_each = var.enable_https ? [1] : []
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
    for_each = !var.enable_https ? [1] : []
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
    Name      = "${var.name}-http"
    Component = "alb"
  })
}

# Lambda target groups put the functions on the same ALB as EC2 and ECS, so all
# three platforms share one entrypoint and one request path. A lambda target
# group takes no port, protocol or vpc_id.
#
# Health checks disabled. On a lambda target group the ALB health check is a real
# invocation, so it would invoke each function every 30 s outside the load test,
# creating extra execution environments and skewing cold-start metrics.
resource "aws_lb_target_group" "lambda" {
  for_each = var.lambda_function_arns

  name        = substr(replace("${var.name}-${each.key}-lb", "_", "-"), 0, 32)
  target_type = "lambda"

  # Set even though the check is disabled: the API validates them anyway, and for
  # target_type = "lambda" both default to 30, which fails validation.
  health_check {
    enabled  = false
    interval = 35
    timeout  = 30
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-lambda"
    App       = each.key
    Platform  = "lambda"
    Component = "alb"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lambda_permission" "alb" {
  for_each = var.lambda_function_arns

  statement_id  = "AllowInvokeFromALB"
  action        = "lambda:InvokeFunction"
  function_name = each.value
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda[each.key].arn
}

resource "aws_lb_target_group_attachment" "lambda" {
  for_each = var.lambda_function_arns

  target_group_arn = aws_lb_target_group.lambda[each.key].arn
  target_id        = each.value

  depends_on = [aws_lambda_permission.alb]
}

resource "aws_lb_listener_rule" "http_ec2" {
  for_each = !var.enable_https ? {
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

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-ec2-http"
    Component = "alb"
    Platform  = "ec2"
    App       = each.key
  })
}

resource "aws_lb_listener_rule" "http_ecs" {
  for_each = !var.enable_https ? {
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

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-ecs-http"
    Component = "alb"
    Platform  = "ecs"
    App       = each.key
  })
}

resource "aws_lb_listener_rule" "http_lambda" {
  for_each = !var.enable_https ? {
    for k, a in var.apps : k => a
    if a.host_lambda != "" && contains(keys(var.lambda_function_arns), k)
  } : {}

  listener_arn = aws_lb_listener.http.arn
  priority     = 70 + index(keys(var.apps), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host_lambda]
    }
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-lambda-http"
    Component = "alb"
    Platform  = "lambda"
    App       = each.key
  })
}

resource "aws_lb_listener" "https" {
  count = var.enable_https ? 1 : 0

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
    Name      = "${var.name}-https"
    Component = "alb"
  })
}

resource "aws_lb_listener_rule" "https_ec2" {
  for_each = var.enable_https ? {
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

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-ec2-https"
    Component = "alb"
    Platform  = "ec2"
    App       = each.key
  })
}

resource "aws_lb_listener_rule" "https_ecs" {
  for_each = var.enable_https ? {
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

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-ecs-https"
    Component = "alb"
    Platform  = "ecs"
    App       = each.key
  })
}

resource "aws_lb_listener_rule" "https_lambda" {
  for_each = var.enable_https ? {
    for k, a in var.apps : k => a
    if a.host_lambda != "" && contains(keys(var.lambda_function_arns), k)
  } : {}

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 70 + index(keys(var.apps), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host_lambda]
    }
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.key}-lambda-https"
    Component = "alb"
    Platform  = "lambda"
    App       = each.key
  })
}
