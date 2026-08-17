data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023_ami" {
  count = var.ec2_ami_id == "" ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_ssm_parameter" "ecs_ami" {
  count = var.ecs_ami_id == "" ? 1 : 0
  name  = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

module "network" {
  source = "./modules/network"

  name               = local.name_prefix
  cidr_block         = var.vpc_cidr
  enable_nat_gateway = var.enable_nat_gateway
  tags               = local.tags
}

module "security_groups" {
  source = "./modules/security_groups"

  name      = local.name_prefix
  vpc_id    = module.network.vpc_id
  app_ports = { for k, a in local.apps : k => a.port }
  tags      = local.tags
}

module "ecr" {
  source = "./modules/ecr"

  names = { for k, a in local.apps : k => a.ecr_name }
  tags  = local.tags
}

module "secrets" {
  source = "./modules/secrets"

  name = local.name_prefix
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = module.secrets.db_secret_id
  secret_string = jsonencode({
    username = var.rds_username
    password = module.secrets.db_password
    host     = var.enable_rds ? module.rds[0].address : ""
    port     = 5432
    dbname   = var.rds_db_name
    engine   = "postgres"
  })
}

module "observability" {
  source = "./modules/observability"

  name               = local.name_prefix
  apps               = { for k, a in local.apps : k => { name = a.name } }
  log_retention_days = var.log_retention_days
  tags               = local.tags
}

module "iam" {
  source = "./modules/iam"

  name                           = local.name_prefix
  aws_region                     = var.aws_region
  aws_account_id                 = data.aws_caller_identity.current.account_id
  secret_arns                    = module.secrets.secret_arns
  ecr_arns                       = values(module.ecr.repository_arns)
  log_group_arns                 = module.observability.log_group_arns
  create_deploy_role             = var.create_deploy_role
  deploy_role_trusted_principals = var.deploy_role_trusted_principals
  tags                           = local.tags
}

module "rds" {
  count  = var.enable_rds ? 1 : 0
  source = "./modules/rds"

  name              = local.name_prefix
  subnet_ids        = module.network.private_subnet_ids
  availability_zone = local.benchmark_az
  security_group_id = module.security_groups.rds_sg_id
  instance_class    = var.rds_instance_class
  engine_version    = var.rds_engine_version
  allocated_storage = var.rds_allocated_storage
  db_name           = var.rds_db_name
  username          = var.rds_username
  password          = module.secrets.db_password
  tags              = local.tags
}

module "acm" {
  count  = local.enable_https ? 1 : 0
  source = "./modules/acm_route53"

  domain_name               = var.domain_name
  route53_zone_id           = var.route53_zone_id
  subject_alternative_names = ["*.${var.domain_name}"]
  tags                      = local.tags
}

module "alb" {
  source = "./modules/alb"

  name              = local.name_prefix
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.security_groups.alb_sg_id
  enable_https      = local.enable_https
  certificate_arn   = local.enable_https ? module.acm[0].certificate_arn : ""
  ssl_policy        = var.alb_ssl_policy
  apps = {
    for k, a in local.apps : k => {
      name        = a.name
      port        = a.port
      health_path = a.health_path
      host_ec2    = a.host_ec2
      host_ecs    = a.host_ecs
      host_lambda = a.host_lambda
    }
  }

  # Empty unless the functions exist and lambda_behind_alb is on, which keeps
  # the ALB appliable before compute is enabled.
  lambda_function_arns = (
    var.enable_lambda && var.lambda_behind_alb
    ? module.lambda_apps[0].function_arns
    : {}
  )

  tags = local.tags
}

resource "aws_route53_record" "alb_alias" {
  for_each = local.enable_https ? local.public_hostnames : {}

  zone_id = var.route53_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

module "ec2_apps" {
  count  = var.enable_ec2 ? 1 : 0
  source = "./modules/ec2_apps"

  name                  = local.name_prefix
  ami_id                = local.ec2_ami_id
  instance_type         = var.ec2_instance_type
  subnet_ids            = local.compute_subnet_ids
  security_group_ids    = [module.security_groups.ec2_sg_id]
  instance_profile_name = module.iam.ec2_instance_profile_name
  cpu_credits           = var.cpu_credits

  # The app container is capped at the same budget as the ECS task, so the
  # host size does not change how much CPU the application actually gets.
  container_cpus      = var.ecs_task_cpu / 1024
  container_memory_mb = var.ecs_task_memory
  apps = {
    for k, a in local.apps : k => {
      name      = a.name
      port      = a.port
      needs_rds = a.needs_rds
    }
  }
  target_group_arns = module.alb.ec2_target_group_arns
  image_refs        = local.image_refs
  db_secret_arn     = module.secrets.db_secret_arn
  jwt_secret_arn    = module.secrets.jwt_secret_arn
  aws_region        = var.aws_region
  run_nonce         = var.run_nonce
  tags              = local.tags

  # user_data pulls from ECR over the NAT gateway. Subnets alone are not
  # enough: they exist before the private route, and an instance booting in
  # that window fails docker login.
  depends_on = [module.network]
}

module "ecs_cluster" {
  count  = var.enable_ecs ? 1 : 0
  source = "./modules/ecs_cluster"

  name                            = local.name_prefix
  vpc_id                          = module.network.vpc_id
  private_subnet_ids              = local.compute_subnet_ids
  ami_id                          = local.ecs_ami_id
  instance_type                   = var.ecs_instance_type
  cpu_credits                     = var.cpu_credits
  asg_desired                     = var.ecs_asg_desired
  asg_min                         = var.ecs_asg_min
  asg_max                         = var.ecs_asg_max
  ecs_instance_security_group_ids = [module.security_groups.ecs_instances_sg_id]
  task_security_group_ids         = [module.security_groups.ecs_sg_id]
  execution_role_arn              = module.iam.ecs_execution_role_arn
  task_role_arn                   = module.iam.ecs_task_role_arn
  apps = {
    for k, a in local.apps : k => {
      name          = a.name
      port          = a.port
      needs_rds     = a.needs_rds
      health_path   = a.health_path
      db_schema_ecs = try(a.db_schema_ecs, "ecs")
    }
  }
  image_refs            = local.image_refs
  target_group_arns     = module.alb.ecs_target_group_arns
  task_cpu              = var.ecs_task_cpu
  task_memory           = var.ecs_task_memory
  service_desired_count = var.ecs_service_desired_count
  db_secret_arn         = module.secrets.db_secret_arn
  jwt_secret_arn        = module.secrets.jwt_secret_arn
  aws_region            = var.aws_region
  run_nonce             = var.run_nonce
  tags                  = local.tags

  # Listener rules must exist so ECS target groups are associated with the ALB.
  # Network for the NAT route, as in ec2_apps.
  depends_on = [module.alb, module.network]
}

module "lambda_apps" {
  count  = var.enable_lambda ? 1 : 0
  source = "./modules/lambda_apps"

  name = local.name_prefix
  apps = {
    for k, a in local.apps : k => {
      name             = a.name
      port             = a.port
      needs_rds        = a.needs_rds
      db_schema_lambda = try(a.db_schema_lambda, "lambda")
    }
  }
  image_refs                = local.lambda_image_refs
  role_arns                 = module.iam.lambda_role_arns
  memory_mb                 = var.lambda_memory_mb
  reserved_concurrency      = var.lambda_reserved_concurrency
  ephemeral_mb              = var.lambda_ephemeral_mb
  timeout_s                 = var.lambda_timeout_s
  function_url_auth_type    = var.lambda_function_url_auth_type
  private_subnet_ids        = local.compute_subnet_ids
  lambda_security_group_ids = [module.security_groups.lambda_sg_id]
  db_host                   = var.enable_rds ? module.rds[0].address : ""
  db_port                   = 5432
  db_name                   = var.rds_db_name
  db_username               = var.rds_username
  db_password               = module.secrets.db_password
  jwt_secret                = module.secrets.jwt_secret
  run_nonce                 = var.run_nonce
  tags                      = local.tags
}

# In-region Artillery host. Off by default: it is only needed for AWS runs, and
# a workstation is fine for the local stack. See modules/loadgen for why the
# workstation is not fine for AWS runs.
module "loadgen" {
  count  = var.enable_loadgen ? 1 : 0
  source = "./modules/loadgen"

  name              = local.name_prefix
  account_id        = data.aws_caller_identity.current.account_id
  aws_region        = var.aws_region
  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.public_subnet_ids[0]
  ami_id            = local.ec2_ami_id
  instance_type     = var.loadgen_instance_type
  artillery_version = var.artillery_version
  form_data_version = var.form_data_version
  tags              = local.tags
}

resource "aws_budgets_budget" "monthly" {
  count = length(var.budget_alert_emails) > 0 ? 1 : 0

  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

resource "local_file" "benchmark_targets" {
  count = var.write_benchmark_targets ? 1 : 0

  filename = "${path.module}/generated/benchmark-targets.json"
  content = jsonencode({
    region  = var.aws_region
    alb_dns = module.alb.alb_dns_name
    scheme  = local.enable_https ? "https" : "http"
    # When true, load tests reach the functions through the ALB like EC2 and
    # ECS do. The Function URLs stay published regardless and remain what
    # Prometheus scrapes for /metrics.
    lambda_behind_alb = var.enable_lambda && var.lambda_behind_alb
    hostnames         = local.public_hostnames
    lambda_urls       = try(module.lambda_apps[0].function_urls, {})
    ecr               = module.ecr.repository_urls
    rds_host          = try(module.rds[0].address, null)
    # Consumed by scripts/loadgen-*.sh so a run does not need terraform output.
    loadgen = var.enable_loadgen ? {
      instance_id = module.loadgen[0].instance_id
      bucket      = module.loadgen[0].bucket
    } : null
    image_refs = {
      app    = local.image_refs
      lambda = local.lambda_image_refs
    }
    log_groups = module.observability.log_group_names
    security_groups = {
      alb           = module.security_groups.alb_sg_id
      ec2           = module.security_groups.ec2_sg_id
      ecs_tasks     = module.security_groups.ecs_sg_id
      ecs_instances = module.security_groups.ecs_instances_sg_id
      lambda        = module.security_groups.lambda_sg_id
      rds           = module.security_groups.rds_sg_id
    }
  })
}
