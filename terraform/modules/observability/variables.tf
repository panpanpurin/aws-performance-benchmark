variable "name" {
  type        = string
  description = "Name prefix."
}

variable "apps" {
  type = map(object({
    name = string
  }))
  description = "App map (keys used in log group paths)."
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention in days."
  default     = 14
}

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}
