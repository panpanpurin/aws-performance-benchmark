output "endpoint" {
  description = "RDS endpoint host:port."
  value       = aws_db_instance.this.endpoint
  sensitive   = true
}

output "address" {
  description = "RDS hostname."
  value       = aws_db_instance.this.address
  sensitive   = true
}

output "port" {
  description = "RDS port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name."
  value       = aws_db_instance.this.db_name
}

output "resource_id" {
  description = "RDS resource id."
  value       = aws_db_instance.this.resource_id
}

output "arn" {
  description = "RDS instance ARN."
  value       = aws_db_instance.this.arn
}
