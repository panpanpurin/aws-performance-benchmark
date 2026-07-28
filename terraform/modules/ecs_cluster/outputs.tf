output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_names" {
  description = "Map of app key to ECS service name."
  value       = { for k, s in aws_ecs_service.app : k => s.name }
}

output "task_definition_arns" {
  description = "Map of app key to task definition ARN."
  value       = { for k, t in aws_ecs_task_definition.app : k => t.arn }
}

output "ecs_instance_profile_name" {
  description = "Instance profile used by ECS container instances."
  value       = aws_iam_instance_profile.ecs_instance.name
}
