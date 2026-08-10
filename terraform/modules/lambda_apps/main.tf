resource "aws_lambda_function" "app" {
  for_each = var.apps

  function_name = "${var.name}-${each.value.name}"
  role          = var.role_arns[each.key]
  package_type  = "Image"
  image_uri     = var.image_refs[each.key]
  memory_size   = var.memory_mb
  timeout       = var.timeout_s
  architectures = ["x86_64"]

  # Caps how many sandboxes may run at once. Set to 1 so Lambda has the same
  # number of workers as one EC2 container and one ECS task, which keeps
  # provisioned capacity equal across platforms. -1 removes the cap and lets
  # Lambda scale to the account limit, which measures elasticity instead.
  reserved_concurrent_executions = var.reserved_concurrency

  ephemeral_storage {
    size = var.ephemeral_mb
  }

  # Every function is attached to the VPC.
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = var.lambda_security_group_ids
  }

  environment {
    variables = merge(
      {
        NODE_ENV = "production"
        PORT     = tostring(each.value.port)
        # Unread by the app. Changing it replaces the execution environments, so
        # the repetition contributes cold starts instead of reusing warm ones.
        RUN_NONCE = var.run_nonce
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

# Public Function URL (auth NONE) needs both invoke URL + invoke function
resource "aws_lambda_permission" "function_url_public" {
  for_each = var.function_url_auth_type == "NONE" ? aws_lambda_function.app : {}

  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = each.value.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "function_invoke_public" {
  for_each = var.function_url_auth_type == "NONE" ? aws_lambda_function.app : {}

  statement_id  = "AllowPublicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "*"
}
