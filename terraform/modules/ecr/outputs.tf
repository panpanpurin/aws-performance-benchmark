output "repository_urls" {
  description = "Map of app key to ECR repository URL."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Map of app key to ECR repository ARN."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}

output "repository_names" {
  description = "Map of app key to repository name."
  value       = { for k, r in aws_ecr_repository.this : k => r.name }
}
