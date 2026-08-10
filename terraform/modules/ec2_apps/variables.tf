variable "name" {
  type        = string
  description = "Name prefix."
}

variable "ami_id" {
  type        = string
  description = "Pinned AMI id."
}

variable "instance_type" {
  type        = string
  description = "Instance type."
  default     = "c6i.large"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet ids (instances spread across list)."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security groups for instances."
}

variable "instance_profile_name" {
  type        = string
  description = "IAM instance profile name."
}

variable "apps" {
  type = map(object({
    name      = string
    port      = number
    needs_rds = bool
  }))
  description = "Apps to create one instance each."
}

variable "target_group_arns" {
  type        = map(string)
  description = "Map of app key to ALB target group ARN."
  default     = {}
}

variable "image_refs" {
  type        = map(string)
  description = "Map of app key to container image ref (repo:tag or repo@digest)."
  default     = {}
}

variable "db_secret_arn" {
  type        = string
  description = "AniLove DB secret ARN."
  default     = ""
}

variable "jwt_secret_arn" {
  type        = string
  description = "AniLove JWT secret ARN."
  default     = ""
}

variable "aws_region" {
  type        = string
  description = "Region for AWS CLI in user_data."
}

variable "container_cpus" {
  type        = number
  description = "vCPUs granted to the app container (docker --cpus). Must match the ECS task's cpu units / 1024."
  default     = 1
}

variable "container_memory_mb" {
  type        = number
  description = "Memory granted to the app container in MB (docker --memory). Must match the ECS task memory."
  default     = 1024
}

variable "cpu_credits" {
  type        = string
  description = "CPU credit mode for burstable instance types: standard or unlimited. Ignored on non-burstable types."
  default     = "standard"
}

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}

variable "run_nonce" {
  type        = string
  description = "Opaque value that forces fresh compute when it changes. See the root variable."
  default     = ""
}
