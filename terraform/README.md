# Terraform

AWS stack for the three-app EC2 / ECS / Lambda benchmark.
Design: [docs/INFRASTRUCTURE.md](../docs/INFRASTRUCTURE.md), [docs/IAM.md](../docs/IAM.md).

## Managed resources

| Area | Module / file |
|------|----------------|
| VPC, subnets, NAT | `modules/network` |
| Security groups | `modules/security_groups` |
| ECR | `modules/ecr` |
| Secrets (DB, JWT) | `modules/secrets` + root secret version |
| CloudWatch logs + retention | `modules/observability` |
| Runtime IAM + deploy policy | `modules/iam` |
| RDS (AniLove) | `modules/rds` |
| ACM DNS validation | `modules/acm_route53` |
| ALB + target groups | `modules/alb` |
| EC2 apps | `modules/ec2_apps` (`enable_ec2`) |
| ECS cluster + services | `modules/ecs_cluster` (`enable_ecs`) |
| Lambda + Function URLs | `modules/lambda_apps` (`enable_lambda`) |
| Remote state | `bootstrap/` |
| Pins | AMI (var or SSM), image digests/tags, TLS policy, sizes |
| Tags | `providers.tf` default_tags, `locals.tags` |
| Benchmark targets file | `generated/benchmark-targets.json` |

Docker image builds, Artillery runs, Grafana dashboards under `local/` and `benchmarks/`.

## Apply order

### 1. State backend (once)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=YOUR_UNIQUE_BUCKET"
```

Copy `backend_config` into `../versions.tf`, then `terraform init -migrate-state` in the root.

### 2. Core stack

Always created: network, security groups, ECR, secrets, IAM, ALB, log groups. RDS is on by default (`enable_rds`).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit domain, zone, tags as needed
terraform init
terraform plan
terraform apply
```

HTTPS and DNS aliases need `domain_name` and `route53_zone_id`. Without them the ALB uses HTTP only.

### 3. Images

Build and push:

| Image | Dockerfile | Suggested tag |
|-------|------------|---------------|
| EC2/ECS | `apps/*/Dockerfile` | `latest` or digest |
| Lambda | `apps/*/Dockerfile.lambda` | `lambda` or digest |

Use `ecr_repository_urls` from outputs. Pin digests in `tfvars` after the first push.

### 4. Compute

Set flags in `tfvars` after images exist:

```hcl
enable_ec2    = true
enable_ecs    = true
enable_lambda = true
```

Empty `ec2_ami_id` / `ecs_ami_id` resolve via SSM (latest AL2023 / ECS-optimized). Pin AMI ids for stable runs.

## Deploy IAM

- Attach output `iam_deploy_policy_arn` to SSO or CI.
- Or set `create_deploy_role = true` and `deploy_role_trusted_principals`.

Runtime roles: EC2 instance profile, ECS execution + task, Lambda per app.

## Outputs

| Output | Use |
|--------|-----|
| `alb_dns_name`, `public_hostnames` | Artillery / Prometheus EC2+ECS |
| `lambda_function_urls` | Artillery / Prometheus Lambda |
| `ecr_repository_urls` | docker push |
| `rds_address` | debug / secret contents |
| `security_group_ids`, `log_group_names` | ops |
| `benchmark_targets_file` | `generated/benchmark-targets.json` |

Copy hostnames and Function URLs into:

- `benchmarks/suites/*/prometheus.yml`
- `benchmarks/suites/*/artillery/test-*.yml`

## Layout

```text
terraform/
  versions.tf providers.tf variables.tf locals.tf main.tf outputs.tf
  terraform.tfvars.example
  bootstrap/
  modules/
  generated/          # gitignored; targets JSON
```
