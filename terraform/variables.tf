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
  description = "EC2 app instance type. Non-burstable keeps CPU credits out of the comparison."
  default     = "c6i.large"
}

variable "ecs_instance_type" {
  type        = string
  description = "ECS container instance type. Matches ec2_instance_type so both platforms share a host profile."
  default     = "c6i.large"
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
  description = "Lambda memory (MB). 1769 is the point where Lambda allocates one full vCPU, matching the 1 vCPU given to EC2 and ECS."
  default     = 1769
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
  description = "RDS instance class. Must be non-burstable for the same reason the EC2 and ECS hosts are: CPU credit balance carries across runs, so a burstable database would make repetitions measure a degrading system rather than repeated samples of the same one. The database is shared by all three platforms and sits in the critical path of the only I/O-bound workload, so that variance would land directly on the reported database wait. Burstable classes also cannot run Performance Insights."
  default     = "db.m6g.large"

  validation {
    condition     = !can(regex("^db\\.t[0-9]", var.rds_instance_class))
    error_message = "Burstable classes (db.t2/t3/t4g) make repeated runs non-comparable and cannot run Performance Insights. Use a non-burstable class such as db.m6g.large."
  }
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

variable "budget_alert_emails" {
  type        = list(string)
  description = "Recipients for the monthly cost alarm. Empty disables the budget."
  default     = []
}

variable "monthly_budget_usd" {
  type        = number
  description = "Monthly cost threshold. A session costs a few dollars; a stack left running after a failed destroy costs hundreds."
  default     = 50
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

variable "cpu_credits" {
  type        = string
  description = "CPU credit mode when a burstable instance type is used: standard or unlimited. Applied to EC2 apps and ECS instances alike so neither platform bursts while the other throttles. Ignored on non-burstable types."
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "Must be standard or unlimited."
  }
}

variable "lambda_behind_alb" {
  type        = bool
  description = "Register the Lambda functions as targets of the shared ALB, so all three platforms are reached through the same load balancer and the same request path. The Function URLs stay in place either way and remain the endpoint used for Prometheus scrapes."
  default     = true
}

variable "lambda_reserved_concurrency" {
  type        = number
  description = "Max concurrent executions per Lambda function. 1 gives Lambda the same worker count as one EC2 container and one ECS task, so provisioned capacity is equal across platforms and the measurement isolates per-request cost. Set to -1 to remove the cap and measure elasticity instead."
  default     = 1

  validation {
    condition     = var.lambda_reserved_concurrency == -1 || var.lambda_reserved_concurrency >= 1
    error_message = "Must be -1 (uncapped) or a positive integer."
  }
}

variable "enable_loadgen" {
  type        = bool
  description = "Provision the in-region Artillery host. Off by default. Required for AWS runs: a workstation uplink cannot supply the load the measured phase rates ask for, and a saturated generator biases all three platforms unevenly rather than failing cleanly."
  default     = false
}

variable "loadgen_instance_type" {
  type        = string
  description = "Load generator size. Must not be the bottleneck - see modules/loadgen/variables.tf."
  default     = "c6i.xlarge"
}

variable "artillery_version" {
  type        = string
  description = "Artillery version installed on the load generator. Kept equal to the version benchmarks/scripts/run-parallel.sh resolves locally."
  default     = "2.0.23"
}

# EC2 took a subnet by application index, the ECS ASG spanned every private
# subnet, and RDS took whichever zone AWS picked, so an app's EC2 instance could
# sit in a different zone from the database while its ECS task did not, paying a
# cross-zone hop per query. That produced a 2.5x EC2-versus-ECS difference on the
# I/O-bound workload that was placement, not platform.
#
# The ALB and the DB subnet group still span several zones, as AWS requires;
# only the instances are pinned.
variable "pin_compute_az" {
  description = "Place EC2, ECS, Lambda and RDS in a single availability zone so placement is not a variable."
  type        = bool
  default     = true
}

variable "benchmark_az_index" {
  description = "Index into the private subnet list selecting the pinned zone. Ignored when pin_compute_az is false."
  type        = number
  default     = 0

  validation {
    condition     = var.benchmark_az_index >= 0
    error_message = "benchmark_az_index must be zero or greater."
  }
}

variable "run_nonce" {
  type        = string
  description = "Opaque value fed to all three compute modules. Changing it and applying replaces the EC2 instances, the ECS hosts and tasks, and the Lambda execution environments, so a repetition starts on fresh compute without destroying the stack. Cold start is recorded once per container, so its sample size is the number of repetitions that changed this."
  default     = ""
}
