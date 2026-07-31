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
      host_ec2         = "anilove-ec2.${local.dns_suffix}"
      host_ecs         = "anilove-ecs.${local.dns_suffix}"
    }
    csv = {
      name        = "csv-processor"
      port        = 8000
      needs_rds   = false
      ecr_name    = "${var.project_name}/csv-processor"
      health_path = "/health"
      host_ec2    = "csv-processor-ec2.${local.dns_suffix}"
      host_ecs    = "csv-processor-ecs.${local.dns_suffix}"
    }
    thumbnail = {
      name        = "thumbnail-generator"
      port        = 3001
      needs_rds   = false
      ecr_name    = "${var.project_name}/thumbnail-generator"
      health_path = "/health"
      host_ec2    = "thumbnail-generator-ec2.${local.dns_suffix}"
      host_ecs    = "thumbnail-ecs.${local.dns_suffix}"
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

  public_hostnames = merge(
    { for k, a in local.apps : "${k}_ec2" => a.host_ec2 if a.host_ec2 != "" },
    { for k, a in local.apps : "${k}_ecs" => a.host_ecs if a.host_ecs != "" }
  )
}
