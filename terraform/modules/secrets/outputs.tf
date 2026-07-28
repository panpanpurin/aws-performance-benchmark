output "db_secret_arn" {
  description = "ARN of the AniLove DB secret."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_id" {
  description = "Id of the AniLove DB secret."
  value       = aws_secretsmanager_secret.db.id
}

output "jwt_secret_arn" {
  description = "ARN of the AniLove JWT secret."
  value       = aws_secretsmanager_secret.jwt.arn
}

output "secret_arns" {
  description = "List of secret ARNs for IAM policies."
  value = [
    aws_secretsmanager_secret.db.arn,
    aws_secretsmanager_secret.jwt.arn,
  ]
}

output "secret_arns_map" {
  description = "Named secret ARNs."
  value = {
    db  = aws_secretsmanager_secret.db.arn
    jwt = aws_secretsmanager_secret.jwt.arn
  }
}

output "db_password" {
  description = "Generated DB master password (for RDS and secret version)."
  value       = random_password.db.result
  sensitive   = true
}

output "jwt_secret" {
  description = "Generated JWT secret value."
  value       = random_password.jwt.result
  sensitive   = true
}
