variable "name" {
  type        = string
  description = "Name prefix."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet ids for the DB subnet group."
}

variable "security_group_id" {
  type        = string
  description = "RDS security group id."
}

variable "instance_class" {
  type        = string
  description = "RDS instance class."
  default     = "db.t4g.micro"
}

variable "engine_version" {
  type        = string
  description = "PostgreSQL engine version pin."
}

variable "allocated_storage" {
  type        = number
  description = "Allocated storage (GiB)."
  default     = 20
}

variable "db_name" {
  type        = string
  description = "Initial database name."
}

variable "username" {
  type        = string
  description = "Master username."
}

variable "password" {
  type        = string
  description = "Master password (from secrets module)."
  sensitive   = true
}

variable "tags" {
  type        = map(string)
  description = "Extra tags."
  default     = {}
}
