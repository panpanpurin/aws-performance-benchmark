output "instance_id" {
  value       = aws_instance.loadgen.id
  description = "Target for aws ssm send-command."
}

output "public_ip" {
  value       = aws_instance.loadgen.public_ip
  description = "Informational only; no inbound port is open."
}

output "bucket" {
  value       = aws_s3_bucket.artifacts.bucket
  description = "Where the Artillery suites and result files are staged."
}

output "security_group_id" {
  value       = aws_security_group.loadgen.id
  description = "Load generator security group."
}
