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
  certificate_arn   = local.enable_https ? module.acm[0].certificate_arn : ""
  ssl_policy        = var.alb_ssl_policy
  apps = {
    for k, a in local.apps : k => {
      name        = a.name
      port        = a.port
      health_path = a.health_path
      host_ec2    = a.host_ec2
      host_ecs    = a.host_ecs
    }
  }
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
  subnet_ids            = module.network.private_subnet_ids
  security_group_ids    = [module.security_groups.ec2_sg_id]
  instance_profile_name = module.iam.ec2_instance_profile_name
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
  tags              = local.tags
}

module "ecs_cluster" {
  count  = var.enable_ecs ? 1 : 0
  source = "./modules/ecs_cluster"

  name                            = local.name_prefix
  vpc_id                          = module.network.vpc_id
  private_subnet_ids              = module.network.private_subnet_ids
  ami_id                          = local.ecs_ami_id
  instance_type                   = var.ecs_instance_type
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
  tags                  = local.tags
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
  ephemeral_mb              = var.lambda_ephemeral_mb
  timeout_s                 = var.lambda_timeout_s
  function_url_auth_type    = var.lambda_function_url_auth_type
  private_subnet_ids        = module.network.private_subnet_ids
  lambda_security_group_ids = [module.security_groups.lambda_sg_id]
  db_host                   = var.enable_rds ? module.rds[0].address : ""
  db_port                   = 5432
  db_name                   = var.rds_db_name
  db_username               = var.rds_username
  db_password               = module.secrets.db_password
  jwt_secret                = module.secrets.jwt_secret
  tags                      = local.tags
}

resource "local_file" "benchmark_targets" {
  count = var.write_benchmark_targets ? 1 : 0

  filename = "${path.module}/generated/benchmark-targets.json"
  content = jsonencode({
    region      = var.aws_region
    alb_dns     = module.alb.alb_dns_name
    hostnames   = local.public_hostnames
    lambda_urls = try(module.lambda_apps[0].function_urls, {})
    ecr         = module.ecr.repository_urls
    rds_host    = try(module.rds[0].address, null)
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
