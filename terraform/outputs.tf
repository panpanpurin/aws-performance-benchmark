output "aws_region" {
  description = "Region."
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC id."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet ids."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet ids."
  value       = module.network.private_subnet_ids
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB zone id for Route 53 aliases."
  value       = module.alb.alb_zone_id
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN."
  value       = try(module.acm[0].certificate_arn, null)
}

output "rds_endpoint" {
  description = "RDS endpoint host:port."
  value       = try(module.rds[0].endpoint, null)
  sensitive   = true
}

output "rds_address" {
  description = "RDS hostname."
  value       = try(module.rds[0].address, null)
  sensitive   = true
}

output "ecr_repository_urls" {
  description = "ECR URLs by app."
  value       = module.ecr.repository_urls
}

output "image_refs" {
  description = "EC2/ECS image refs."
  value       = local.image_refs
}

output "lambda_image_refs" {
  description = "Lambda image refs."
  value       = local.lambda_image_refs
}

output "ec2_ami_id" {
  description = "Resolved EC2 AMI id."
  value       = nonsensitive(local.ec2_ami_id)
}

output "ecs_ami_id" {
  description = "Resolved ECS AMI id."
  value       = nonsensitive(local.ecs_ami_id)
}

output "ec2_instance_ids" {
  description = "EC2 instance ids by app."
  value       = try(module.ec2_apps[0].instance_ids, {})
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = try(module.ecs_cluster[0].cluster_name, null)
}

output "lambda_function_urls" {
  description = "Lambda Function URLs."
  value       = try(module.lambda_apps[0].function_urls, {})
}

output "public_hostnames" {
  description = "EC2/ECS hostnames (when domain is set)."
  value       = local.public_hostnames
}

output "log_group_names" {
  description = "CloudWatch log group names."
  value       = module.observability.log_group_names
}

output "security_group_ids" {
  description = "Security group ids."
  value = {
    alb           = module.security_groups.alb_sg_id
    ec2           = module.security_groups.ec2_sg_id
    ecs_tasks     = module.security_groups.ecs_sg_id
    ecs_instances = module.security_groups.ecs_instances_sg_id
    lambda        = module.security_groups.lambda_sg_id
    rds           = module.security_groups.rds_sg_id
  }
}

output "secret_arns" {
  description = "AniLove secret ARNs."
  value       = module.secrets.secret_arns_map
  sensitive   = true
}

output "iam_deploy_policy_arn" {
  description = "Deploy policy ARN for SSO or CI."
  value       = module.iam.deploy_policy_arn
}

output "iam_deploy_role_arn" {
  description = "Deploy role ARN if created."
  value       = module.iam.deploy_role_arn
}

output "iam_runtime" {
  description = "Runtime role identifiers."
  value = {
    ec2_instance_profile = module.iam.ec2_instance_profile_name
    ecs_execution_role   = module.iam.ecs_execution_role_arn
    ecs_task_role        = module.iam.ecs_task_role_arn
    lambda_role_arns     = module.iam.lambda_role_arns
  }
}

output "benchmark_targets_file" {
  description = "Path to generated targets JSON."
  value       = try(abspath(local_file.benchmark_targets[0].filename), null)
}

output "tags" {
  description = "Default tags."
  value       = local.tags
}

output "loadgen_instance_id" {
  value       = try(module.loadgen[0].instance_id, null)
  description = "In-region Artillery host; target for aws ssm send-command."
}

output "loadgen_bucket" {
  value       = try(module.loadgen[0].bucket, null)
  description = "Where Artillery suites and result files are staged."
}
