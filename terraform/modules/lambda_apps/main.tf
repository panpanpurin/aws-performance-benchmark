resource "aws_lambda_function" "app" {
  for_each = var.apps

  function_name = "${var.name}-${each.value.name}"
  role          = var.role_arns[each.key]
  package_type  = "Image"
  image_uri     = var.image_refs[each.key]
  memory_size   = var.memory_mb
  timeout       = var.timeout_s
  architectures = ["x86_64"]

  ephemeral_storage {
    size = var.ephemeral_mb
  }

  dynamic "vpc_config" {
    for_each = each.value.needs_rds ? [1] : []
    content {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = var.lambda_security_group_ids
    }
  }

  environment {
    variables = merge(
      {
        NODE_ENV = "production"
        PORT     = tostring(each.value.port)
      },
      each.value.needs_rds ? {
        DB_HOST     = var.db_host
        DB_PORT     = tostring(var.db_port)
        DB_NAME     = var.db_name
        DB_USER     = var.db_username
        DB_PASSWORD = var.db_password
        DB_SCHEMA   = coalesce(try(each.value.db_schema_lambda, null), "lambda")
        DB_SSL      = "true"
        JWT_SECRET  = var.jwt_secret
      } : {}
    )
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-${each.value.name}"
    App       = each.key
    Platform  = "lambda"
    Component = "lambda"
  })
}

resource "aws_lambda_function_url" "app" {
  for_each = aws_lambda_function.app

  function_name      = each.value.function_name
  authorization_type = var.function_url_auth_type

  cors {
    allow_credentials = false
    allow_origins     = ["*"]
    allow_methods     = ["*"]
    allow_headers     = ["*"]
    max_age           = 86400
  }
}
