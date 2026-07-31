# One log group per app per platform. The map key is "<platform>/<app>", which
# is split back out below to tag each group with its own Platform and App.
locals {
  groups = merge(
    { for k, a in var.apps : "ec2/${k}" => "/ec2/${a.name}" },
    { for k, a in var.apps : "ecs/${k}" => "/ecs/${a.name}" },
    { for k, a in var.apps : "lambda/${k}" => "/aws/lambda/${var.name}-${a.name}" },
  )
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.groups

  name              = each.value
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name      = each.value
    Component = "observability"
    Platform  = split("/", each.key)[0]
    App       = split("/", each.key)[1]
  })
}
