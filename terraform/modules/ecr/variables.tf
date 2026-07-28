variable "names" {
  type        = map(string)
  description = "Map of app key to repository name (e.g. anilove -> project/anilove)."
}

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}

variable "scan_on_push" {
  type        = bool
  description = "Enable image scan on push."
  default     = true
}

variable "image_tag_mutability" {
  type        = string
  description = "MUTABLE or IMMUTABLE. Prefer IMMUTABLE when pinning digests only."
  default     = "MUTABLE"
}
