output "log_group_names" {
  description = "Map of logical key to log group name."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.name }
}

output "log_group_arns" {
  description = "List of log group ARNs (base + :* for IAM)."
  value = flatten([
    for g in aws_cloudwatch_log_group.this : [g.arn, "${g.arn}:*"]
  ])
}

output "log_group_arns_map" {
  description = "Map of logical key to log group ARN."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.arn }
}
