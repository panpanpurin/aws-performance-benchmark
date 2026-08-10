variable "name" {
  type        = string
  description = "Name prefix."
}

variable "apps" {
  type = map(object({
    name             = string
    port             = number
    needs_rds        = bool
    db_schema_lambda = optional(string)
  }))
  description = "Apps to deploy."
}

variable "image_refs" {
  type        = map(string)
  description = "ECR image URI by app (Dockerfile.lambda)."
}

variable "role_arns" {
  type        = map(string)
  description = "Execution role ARN by app."
}

variable "memory_mb" {
  type    = number
  default = 1024
}

variable "ephemeral_mb" {
  type    = number
  default = 1024
}

variable "timeout_s" {
  type    = number
  default = 30
}

variable "function_url_auth_type" {
  type    = string
  default = "NONE"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnets for VPC-attached functions."
  default     = []
}

variable "lambda_security_group_ids" {
  type        = list(string)
  description = "Security groups for VPC-attached functions."
  default     = []
}

variable "db_host" {
  type      = string
  default   = ""
  sensitive = true
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type    = string
  default = ""
}

variable "db_username" {
  type    = string
  default = ""
}

variable "db_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "jwt_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "reserved_concurrency" {
  type        = number
  description = "Max concurrent executions per function. 1 matches the single worker EC2 and ECS each get; -1 removes the cap."
  default     = 1
}

variable "run_nonce" {
  type        = string
  description = "Opaque value that forces fresh compute when it changes. See the root variable."
  default     = ""
}
