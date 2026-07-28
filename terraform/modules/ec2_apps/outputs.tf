output "instance_ids" {
  description = "Map of app key to EC2 instance id."
  value       = { for k, i in aws_instance.app : k => i.id }
}

output "private_ips" {
  description = "Map of app key to private IP."
  value       = { for k, i in aws_instance.app : k => i.private_ip }
}

output "instance_arns" {
  description = "Map of app key to instance ARN."
  value       = { for k, i in aws_instance.app : k => i.arn }
}
