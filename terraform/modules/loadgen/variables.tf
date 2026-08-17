variable "name" {
  type        = string
  description = "Name prefix."
}

variable "account_id" {
  type        = string
  description = "Account id, used to make the artifacts bucket name globally unique."
}

variable "aws_region" {
  type        = string
  description = "Region."
}

variable "vpc_id" {
  type        = string
  description = "VPC id."
}

variable "subnet_id" {
  type        = string
  description = "Public subnet id, so traffic reaches the ALB directly rather than via the shared NAT gateway."
}

variable "ami_id" {
  type        = string
  description = "AMI id (Amazon Linux 2023, same family as the app instances)."
}

variable "instance_type" {
  type        = string
  description = "Must not be the bottleneck: three concurrent Artillery processes at the measured rates need several hundred Mbps. Raise rather than let the client throttle."
  default     = "c6i.xlarge"
}

variable "artillery_version" {
  type        = string
  description = "Matches the version benchmarks/scripts/run-parallel.sh resolves locally."
  default     = "2.0.23"
}

variable "form_data_version" {
  type        = string
  description = "form-data builds the multipart body for the CSV and Thumbnail requests, so its version is an input to the measurement. Unpinned, a generator rebuilt between repetitions would pick up whatever npm resolves that day."
  default     = "4.0.6"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags."
}
