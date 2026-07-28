variable "name" {
  type        = string
  description = "Name prefix for security groups."
}

variable "vpc_id" {
  type        = string
  description = "VPC id."
}

variable "app_ports" {
  type        = map(number)
  description = "Map of app key to listen port (e.g. anilove=3000)."
}

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}
