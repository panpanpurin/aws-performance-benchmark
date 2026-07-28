output "alb_sg_id" {
  description = "ALB security group id."
  value       = aws_security_group.alb.id
}

output "ec2_sg_id" {
  description = "Shared EC2 apps security group id."
  value       = aws_security_group.ec2.id
}

output "ecs_sg_id" {
  description = "ECS tasks security group id."
  value       = aws_security_group.ecs.id
}

output "ecs_instances_sg_id" {
  description = "ECS container instances security group id."
  value       = aws_security_group.ecs_instances.id
}

output "lambda_sg_id" {
  description = "Lambda ENI security group id."
  value       = aws_security_group.lambda.id
}

output "rds_sg_id" {
  description = "RDS security group id."
  value       = aws_security_group.rds.id
}
