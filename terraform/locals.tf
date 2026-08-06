locals {
  name_prefix = var.project_name

  # Applied to every taggable resource through provider default_tags and passed
  # into each module as var.tags.
  #
  # Platform and App are the cost-allocation dimensions: activate both in
  # Billing > Cost allocation tags to break the bill down per compute model.
  # "shared" marks resources the three platforms use in common (VPC, ALB, RDS,
  # ECR), whose cost cannot be attributed to a single platform. Resources
  # belonging to one platform override Platform with ec2, ecs, or lambda.
  tags = merge(
    {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "benchmark"
      Platform    = "shared"
      App         = "shared"
    },
    var.tags_extra
  )

  # Host headers for ALB rules. Always set so target groups attach to the listener
  # even without a public domain (use Host header against the ALB DNS name).
  dns_suffix = var.domain_name != "" ? var.domain_name : "bench.local"

  # DNS labels are short and uniform: <label>-<platform>.<suffix>, one label per
  # app and one per platform. They deliberately do not repeat the full app name
  # (csv-processor, thumbnail-generator), which kept producing inconsistent
  # hosts. All nine are covered by the single *.<domain> wildcard certificate.
  host_label = {
    anilove   = "anilove"
    csv       = "csv"
    thumbnail = "thumb"
  }

  apps = {
    anilove = {
      name             = "anilove"
      port             = 3000
      needs_rds        = true
      ecr_name         = "${var.project_name}/anilove"
      health_path      = "/health"
      db_schema_ec2    = "ec2"
      db_schema_ecs    = "ecs"
      db_schema_lambda = "lambda"
      host_ec2         = "${local.host_label.anilove}-ec2.${local.dns_suffix}"
      host_ecs         = "${local.host_label.anilove}-ecs.${local.dns_suffix}"
      host_lambda      = "${local.host_label.anilove}-lambda.${local.dns_suffix}"
    }
    csv = {
      name        = "csv-processor"
      port        = 8000
      needs_rds   = false
      ecr_name    = "${var.project_name}/csv-processor"
      health_path = "/health"
      host_ec2    = "${local.host_label.csv}-ec2.${local.dns_suffix}"
      host_ecs    = "${local.host_label.csv}-ecs.${local.dns_suffix}"
      host_lambda = "${local.host_label.csv}-lambda.${local.dns_suffix}"
    }
    thumbnail = {
      name        = "thumbnail-generator"
      port        = 3001
      needs_rds   = false
      ecr_name    = "${var.project_name}/thumbnail-generator"
      health_path = "/health"
      host_ec2    = "${local.host_label.thumbnail}-ec2.${local.dns_suffix}"
      host_ecs    = "${local.host_label.thumbnail}-ecs.${local.dns_suffix}"
      host_lambda = "${local.host_label.thumbnail}-lambda.${local.dns_suffix}"
    }
  }

  image_digests = {
    anilove   = var.image_digest_anilove
    csv       = var.image_digest_csv
    thumbnail = var.image_digest_thumbnail
  }

  lambda_image_digests = {
    anilove   = var.image_digest_lambda_anilove
    csv       = var.image_digest_lambda_csv
    thumbnail = var.image_digest_lambda_thumbnail
  }

  image_refs = {
    for k, a in local.apps : k => (
      local.image_digests[k] != ""
      ? "${module.ecr.repository_urls[k]}@${local.image_digests[k]}"
      : "${module.ecr.repository_urls[k]}:${var.ecr_image_tag}"
    )
  }

  lambda_image_refs = {
    for k, a in local.apps : k => (
      local.lambda_image_digests[k] != ""
      ? "${module.ecr.repository_urls[k]}@${local.lambda_image_digests[k]}"
      : "${module.ecr.repository_urls[k]}:${var.ecr_lambda_image_tag}"
    )
  }

  ec2_ami_id = var.ec2_ami_id != "" ? var.ec2_ami_id : try(data.aws_ssm_parameter.al2023_ami[0].value, "")
  ecs_ami_id = var.ecs_ami_id != "" ? var.ecs_ami_id : try(data.aws_ssm_parameter.ecs_ami[0].value, "")

  enable_https = var.domain_name != "" && var.route53_zone_id != ""

  # Lambda hostnames only get a Route 53 alias when the functions are actually
  # behind the ALB; otherwise the record would point at a listener rule that
  # does not exist.
  public_hostnames = merge(
    { for k, a in local.apps : "${k}_ec2" => a.host_ec2 if a.host_ec2 != "" },
    { for k, a in local.apps : "${k}_ecs" => a.host_ecs if a.host_ecs != "" },
    var.enable_lambda && var.lambda_behind_alb ? {
      for k, a in local.apps : "${k}_lambda" => a.host_lambda if a.host_lambda != ""
    } : {}
  )
}

locals {
  # One zone for every compute model and the database. See pin_compute_az.
  benchmark_subnet_index = var.benchmark_az_index % length(module.network.private_subnet_ids)

  compute_subnet_ids = var.pin_compute_az ? [
    module.network.private_subnet_ids[local.benchmark_subnet_index]
  ] : module.network.private_subnet_ids

  benchmark_az = var.pin_compute_az ? module.network.availability_zones[local.benchmark_subnet_index] : null
}
