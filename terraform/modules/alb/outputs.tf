output "alb_arn" {
  description = "ALB ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone id for Route 53 aliases."
  value       = aws_lb.this.zone_id
}

output "ec2_target_group_arns" {
  description = "Map of app key to EC2 target group ARN."
  value       = { for k, tg in aws_lb_target_group.ec2 : k => tg.arn }
}

output "ecs_target_group_arns" {
  description = "Map of app key to ECS target group ARN."
  value       = { for k, tg in aws_lb_target_group.ecs : k => tg.arn }
}

output "https_listener_arn" {
  description = "HTTPS listener ARN when certificate is set."
  value       = try(aws_lb_listener.https[0].arn, null)
}

output "http_listener_arn" {
  description = "HTTP listener ARN."
  value       = aws_lb_listener.http.arn
}
