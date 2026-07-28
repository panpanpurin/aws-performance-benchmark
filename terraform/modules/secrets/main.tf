resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}/anilove/db"
  description             = "AniLove RDS credentials"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, {
    Name      = "${var.name}/anilove/db"
    App       = "anilove"
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${var.name}/anilove/jwt"
  description             = "AniLove JWT secret"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, {
    Name      = "${var.name}/anilove/jwt"
    App       = "anilove"
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id = aws_secretsmanager_secret.jwt.id
  secret_string = jsonencode({
    JWT_SECRET = random_password.jwt.result
  })
}
