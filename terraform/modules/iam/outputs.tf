output "ec2_instance_profile_name" {
  description = "EC2 instance profile name."
  value       = aws_iam_instance_profile.ec2_app.name
}

output "ec2_instance_profile_arn" {
  description = "EC2 instance profile ARN."
  value       = aws_iam_instance_profile.ec2_app.arn
}

output "ec2_role_arn" {
  description = "EC2 instance role ARN."
  value       = aws_iam_role.ec2_app.arn
}

output "ecs_execution_role_arn" {
  description = "ECS task execution role ARN."
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "ECS task role ARN (AniLove secrets)."
  value       = aws_iam_role.ecs_task.arn
}

output "lambda_role_arns" {
  description = "Map of app key to Lambda execution role ARN."
  value       = { for k, r in aws_iam_role.lambda : k => r.arn }
}

output "deploy_policy_arn" {
  description = "ARN of the deploy managed policy (attach to SSO/CI principal)."
  value       = aws_iam_policy.deploy.arn
}

output "deploy_role_arn" {
  description = "Deploy role ARN when create_deploy_role is true."
  value       = try(aws_iam_role.deploy[0].arn, null)
}

output "pass_role_arns" {
  description = "Role ARNs the deploy path may PassRole."
  value = concat(
    [
      aws_iam_role.ec2_app.arn,
      aws_iam_role.ecs_execution.arn,
      aws_iam_role.ecs_task.arn,
    ],
    [for r in aws_iam_role.lambda : r.arn]
  )
}
