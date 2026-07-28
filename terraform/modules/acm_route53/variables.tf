variable "domain_name" {
  type        = string
  description = "Primary certificate domain."
}

variable "route53_zone_id" {
  type        = string
  description = "Hosted zone for DNS validation."
}

variable "subject_alternative_names" {
  type        = list(string)
  description = "Certificate SANs."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags."
  default     = {}
}
