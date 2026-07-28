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
  default     = "t2.micro"
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

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}
