variable "name" {
  type        = string
  description = "Name prefix for network resources."
}

variable "cidr_block" {
  type        = string
  description = "VPC CIDR block."
  default     = "10.40.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of AZs for public/private subnets (ALB needs at least 2)."
  default     = 3
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Create a single NAT gateway for private subnet egress."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Extra tags (default_tags also apply)."
  default     = {}
}
