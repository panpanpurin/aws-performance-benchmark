variable "name" {
  type        = string
  description = "Name prefix used in secret paths."
}

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}

variable "recovery_window_in_days" {
  type        = number
  description = "Secrets Manager recovery window (0 = force delete without recovery)."
  default     = 0
}
