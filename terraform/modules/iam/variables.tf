variable "name" {
  type        = string
  description = "Name prefix for IAM roles."
}

variable "aws_region" {
  type        = string
  description = "AWS region (for log group ARN construction)."
}

variable "aws_account_id" {
  type        = string
  description = "AWS account id (for log group ARN construction)."
}

variable "secret_arns" {
  type        = list(string)
  description = "Secret ARNs runtime roles may read."
  default     = []
}

variable "ecr_arns" {
  type        = list(string)
  description = "ECR repository ARNs allowed for pull."
  default     = []
}

variable "log_group_arns" {
  type        = list(string)
  description = "CloudWatch log group ARNs for put/create. Empty allows wildcard under /project prefixes."
  default     = []
}

variable "create_deploy_role" {
  type        = bool
  description = "Create a deploy IAM role (in addition to the deploy managed policy)."
  default     = false
}

variable "deploy_role_trusted_principals" {
  type        = list(string)
  description = "Principal ARNs trusted to assume the deploy role."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags for IAM roles."
  default     = {}
}
