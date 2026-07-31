data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  ecr_resource_arns = length(var.ecr_arns) > 0 ? var.ecr_arns : ["arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/*"]

  secret_resource_arns = length(var.secret_arns) > 0 ? var.secret_arns : ["arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.name}/*"]

  log_resource_arns = length(var.log_group_arns) > 0 ? var.log_group_arns : [
    "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ec2/*",
    "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ec2/*:*",
    "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ecs/*",
    "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ecs/*:*",
    "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/*",
    "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/*:*",
  ]
}

resource "aws_iam_role" "ec2_app" {
  name               = "${var.name}-ec2-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  description        = "EC2 app instances"

  tags = merge(var.tags, {
    Name      = "${var.name}-ec2-app"
    Component = "iam"
    Platform  = "ec2"
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_app" {
  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPullRepos"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = local.ecr_resource_arns
  }

  statement {
    sid    = "SecretsRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = local.secret_resource_arns
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = local.log_resource_arns
  }
}

resource "aws_iam_role_policy" "ec2_app" {
  name   = "${var.name}-ec2-app"
  role   = aws_iam_role.ec2_app.id
  policy = data.aws_iam_policy_document.ec2_app.json
}

resource "aws_iam_instance_profile" "ec2_app" {
  name = "${var.name}-ec2-app"
  role = aws_iam_role.ec2_app.name

  tags = merge(var.tags, {
    Name      = "${var.name}-ec2-app"
    Component = "iam"
    Platform  = "ec2"
  })
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  description        = "ECS task execution"

  tags = merge(var.tags, {
    Name      = "${var.name}-ecs-execution"
    Component = "iam"
    Platform  = "ecs"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_execution_secrets" {
  statement {
    sid    = "SecretsInject"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = local.secret_resource_arns
  }
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name   = "${var.name}-ecs-execution-secrets"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution_secrets.json
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  description        = "ECS task role (app)"

  tags = merge(var.tags, {
    Name      = "${var.name}-ecs-task"
    Component = "iam"
    Platform  = "ecs"
  })
}

data "aws_iam_policy_document" "ecs_task" {
  statement {
    sid    = "SecretsRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = local.secret_resource_arns
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${var.name}-ecs-task"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task.json
}

resource "aws_iam_role" "lambda" {
  for_each = toset(["anilove", "csv", "thumbnail"])

  name               = "${var.name}-lambda-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  description        = "Lambda execution role for ${each.key}"

  tags = merge(var.tags, {
    Name      = "${var.name}-lambda-${each.key}"
    App       = each.key
    Component = "iam"
    Platform  = "lambda"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each = aws_iam_role.lambda

  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  for_each = { for k, r in aws_iam_role.lambda : k => r if k == "anilove" }

  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_anilove_secrets" {
  statement {
    sid    = "SecretsRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = local.secret_resource_arns
  }
}

resource "aws_iam_role_policy" "lambda_anilove_secrets" {
  name   = "${var.name}-lambda-anilove-secrets"
  role   = aws_iam_role.lambda["anilove"].id
  policy = data.aws_iam_policy_document.lambda_anilove_secrets.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid    = "ReadIdentity"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "iam:GetRole",
      "iam:GetInstanceProfile",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "PassProjectRoles"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.name}-*",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "ecs-tasks.amazonaws.com",
        "lambda.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "ManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
    ]
    resources = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.name}-*",
      "arn:aws:iam::${var.aws_account_id}:instance-profile/${var.name}-*",
      "arn:aws:iam::${var.aws_account_id}:policy/${var.name}-*",
    ]
  }

  statement {
    sid       = "NetworkComputeDataPlane"
    effect    = "Allow"
    actions   = ["ec2:*", "elasticloadbalancing:*", "ecs:*", "lambda:*", "rds:*", "ecr:*", "logs:*", "secretsmanager:*", "ssm:GetParameter", "ssm:GetParameters", "acm:*", "route53:ChangeResourceRecordSets", "route53:GetChange", "route53:ListResourceRecordSets", "route53:ListHostedZones", "route53:GetHostedZone", "autoscaling:*", "application-autoscaling:*", "cloudwatch:*"]
    resources = ["*"]
  }

  statement {
    sid    = "StateBackendOptional"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy" {
  name        = "${var.name}-deploy"
  description = "Terraform apply and ECR push"
  policy      = data.aws_iam_policy_document.deploy.json

  tags = merge(var.tags, {
    Name      = "${var.name}-deploy"
    Component = "iam"
  })
}

data "aws_iam_policy_document" "deploy_assume" {
  count = var.create_deploy_role && length(var.deploy_role_trusted_principals) > 0 ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.deploy_role_trusted_principals
    }
  }
}

resource "aws_iam_role" "deploy" {
  count = var.create_deploy_role && length(var.deploy_role_trusted_principals) > 0 ? 1 : 0

  name               = "${var.name}-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume[0].json
  description        = "Terraform plan/apply and image push"

  tags = merge(var.tags, {
    Name      = "${var.name}-deploy"
    Component = "iam"
  })
}

resource "aws_iam_role_policy_attachment" "deploy" {
  count = length(aws_iam_role.deploy)

  role       = aws_iam_role.deploy[0].name
  policy_arn = aws_iam_policy.deploy.arn
}
