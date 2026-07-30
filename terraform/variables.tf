variable "aws_region" {
  type        = string
  description = "AWS region."
  default     = "ap-northeast-1"
}

variable "project_name" {
  type        = string
  description = "Name prefix for resources and tags."
  default     = "aws-perf-bench"
}

variable "domain_name" {
  type        = string
  description = "Route 53 zone apex. Empty skips ACM and DNS aliases."
  default     = ""
}

variable "route53_zone_id" {
  type        = string
  description = "Hosted zone id for domain_name."
  default     = ""
}

variable "ec2_ami_id" {
  type        = string
  description = "EC2 AMI id. Empty uses the latest AL2023 x86_64 SSM parameter."
  default     = ""
}

variable "ecs_ami_id" {
  type        = string
  description = "ECS-optimized AMI id. Empty uses the SSM recommended parameter."
  default     = ""
}

variable "ec2_instance_type" {
  type        = string
  description = "EC2 app instance type."
  default     = "t2.micro"
}

variable "ecs_instance_type" {
  type        = string
  description = "ECS container instance type."
  default     = "t3.small"
}

variable "ecs_asg_desired" {
  type        = number
  description = "ECS ASG desired capacity."
  default     = 1
}

variable "ecs_asg_min" {
  type        = number
  description = "ECS ASG minimum capacity."
  default     = 0
}

variable "ecs_asg_max" {
  type        = number
  description = "ECS ASG maximum capacity."
  default     = 3
}

variable "ecs_task_cpu" {
  type        = number
  description = "ECS task CPU units (1024 = 1 vCPU)."
  default     = 1024
}

variable "ecs_task_memory" {
  type        = number
  description = "ECS task memory (MiB)."
  default     = 1024
}

variable "ecs_task_memory_reservation" {
  type        = number
  description = "ECS soft memory reservation (MiB). Reserved for future use."
  default     = 512
}

variable "ecs_service_desired_count" {
  type        = number
  description = "Desired count per ECS service."
  default     = 0
}

variable "lambda_memory_mb" {
  type        = number
  description = "Lambda memory (MB)."
  default     = 1024
}

variable "lambda_ephemeral_mb" {
  type        = number
  description = "Lambda ephemeral storage (MB)."
  default     = 1024
}

variable "lambda_timeout_s" {
  type        = number
  description = "Lambda timeout (seconds)."
  default     = 30
}

variable "rds_instance_class" {
  type        = string
  description = "RDS instance class."
  default     = "db.t4g.micro"
}

variable "rds_engine_version" {
  type        = string
  description = "PostgreSQL engine version."
  default     = "17.6"
}

variable "rds_allocated_storage" {
  type        = number
  description = "RDS storage (GiB)."
  default     = 20
}

variable "rds_db_name" {
  type        = string
  description = "Initial database name."
  default     = "anilove"
}

variable "rds_username" {
  type        = string
  description = "RDS master username."
  default     = "anilove"
}

variable "alb_ssl_policy" {
  type        = string
  description = "ALB HTTPS TLS policy."
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention (days)."
  default     = 14
}

variable "ecr_image_tag" {
  type        = string
  description = "Image tag for EC2/ECS (ignored when digest is set)."
  default     = "latest"
}

variable "ecr_lambda_image_tag" {
  type        = string
  description = "Image tag for Lambda (Dockerfile.lambda)."
  default     = "lambda"
}

variable "image_digest_anilove" {
  type        = string
  description = "ECR digest for AniLove EC2/ECS image."
  default     = ""
}

variable "image_digest_csv" {
  type        = string
  description = "ECR digest for CSV EC2/ECS image."
  default     = ""
}

variable "image_digest_thumbnail" {
  type        = string
  description = "ECR digest for Thumbnail EC2/ECS image."
  default     = ""
}

variable "image_digest_lambda_anilove" {
  type        = string
  description = "ECR digest for AniLove Lambda image."
  default     = ""
}

variable "image_digest_lambda_csv" {
  type        = string
  description = "ECR digest for CSV Lambda image."
  default     = ""
}

variable "image_digest_lambda_thumbnail" {
  type        = string
  description = "ECR digest for Thumbnail Lambda image."
  default     = ""
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR."
  default     = "10.40.0.0/16"
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Create one NAT gateway for private subnet egress."
  default     = true
}

variable "enable_ec2" {
  type        = bool
  description = "Create EC2 app instances."
  default     = false
}

variable "enable_ecs" {
  type        = bool
  description = "Create ECS cluster and services."
  default     = false
}

variable "enable_lambda" {
  type        = bool
  description = "Create Lambda functions and Function URLs."
  default     = false
}

variable "enable_rds" {
  type        = bool
  description = "Create shared AniLove RDS."
  default     = true
}

variable "create_deploy_role" {
  type        = bool
  description = "Create an IAM role that can assume for terraform apply."
  default     = false
}

variable "deploy_role_trusted_principals" {
  type        = list(string)
  description = "Principal ARNs allowed to assume the deploy role."
  default     = []
}

variable "lambda_function_url_auth_type" {
  type        = string
  description = "Function URL auth: NONE or AWS_IAM."
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "AWS_IAM"], var.lambda_function_url_auth_type)
    error_message = "Must be NONE or AWS_IAM."
  }
}

variable "write_benchmark_targets" {
  type        = bool
  description = "Write generated/benchmark-targets.json after apply."
  default     = true
}

variable "tags_extra" {
  type        = map(string)
  description = "Extra tags merged into defaults."
  default     = {}
}
