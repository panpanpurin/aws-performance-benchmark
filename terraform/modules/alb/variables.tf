variable "name" {
  type        = string
  description = "Name prefix."
}

variable "vpc_id" {
  type        = string
  description = "VPC id."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Public subnet ids for the ALB."
}

variable "security_group_id" {
  type        = string
  description = "ALB security group id."
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN. Used as a value only; branch on enable_https."
  default     = ""
}

# count and for_each must resolve at plan time. On a fresh apply the certificate
# does not exist yet, so certificate_arn is unknown and cannot decide whether a
# resource exists. This flag comes from domain_name and route53_zone_id, which
# are known from tfvars before anything is created.
variable "enable_https" {
  type        = bool
  description = "Create the HTTPS listener and its rules instead of the HTTP ones."
  default     = false
}

variable "ssl_policy" {
  type        = string
  description = "TLS security policy for the HTTPS listener."
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "apps" {
  type = map(object({
    name        = string
    port        = number
    health_path = string
    host_ec2    = string
    host_ecs    = string
    host_lambda = string
  }))
  description = "Apps for target groups and host-based rules."
}

variable "lambda_function_arns" {
  type        = map(string)
  description = "App key to Lambda function ARN. Empty map leaves the functions off the ALB, reachable only through their Function URLs."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}
