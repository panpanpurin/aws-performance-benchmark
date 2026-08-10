variable "name" {
  type        = string
  description = "Name prefix."
}

variable "vpc_id" {
  type        = string
  description = "VPC id."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for tasks and container instances."
}

variable "ami_id" {
  type        = string
  description = "Pinned ECS-optimized AMI id."
}

variable "instance_type" {
  type        = string
  description = "Container instance type."
  default     = "c6i.large"
}

variable "asg_desired" {
  type    = number
  default = 1
}

variable "asg_min" {
  type    = number
  default = 0
}

variable "asg_max" {
  type    = number
  default = 3
}

variable "ecs_instance_security_group_ids" {
  type        = list(string)
  description = "Security groups for container instances."
}

variable "task_security_group_ids" {
  type        = list(string)
  description = "Security groups for awsvpc tasks."
}

variable "execution_role_arn" {
  type        = string
  description = "ECS task execution role ARN."
}

variable "task_role_arn" {
  type        = string
  description = "ECS task role ARN."
}

variable "apps" {
  type = map(object({
    name          = string
    port          = number
    needs_rds     = bool
    health_path   = string
    db_schema_ecs = optional(string)
  }))
  description = "Apps for task definitions and services."
}

variable "image_refs" {
  type        = map(string)
  description = "Map of app key to image ref."
}

variable "target_group_arns" {
  type        = map(string)
  description = "Map of app key to ECS ALB target group ARN."
}

variable "task_cpu" {
  type    = number
  default = 1024
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "service_desired_count" {
  type    = number
  default = 0
}

variable "db_secret_arn" {
  type    = string
  default = ""
}

variable "jwt_secret_arn" {
  type    = string
  default = ""
}

variable "aws_region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cpu_credits" {
  type        = string
  description = "CPU credit mode for burstable instance types: standard or unlimited. Ignored on non-burstable types."
  default     = "standard"
}

variable "run_nonce" {
  type        = string
  description = "Opaque value that forces fresh compute when it changes. See the root variable."
  default     = ""
}
