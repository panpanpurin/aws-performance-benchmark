# Terraform

AWS stack for the three app EC2 / ECS / Lambda benchmark.

**Region default:** ap-northeast-1 (Tokyo).

| Related | Link |
|---------|------|
| Design | [docs/INFRASTRUCTURE.md](../docs/INFRASTRUCTURE.md) |
| IAM | [docs/IAM.md](../docs/IAM.md) |
| Images and env | [docs/DEPLOY.md](../docs/DEPLOY.md) |

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
| In-region Artillery host + results bucket | `modules/loadgen` (`enable_loadgen`) |
| Remote state | `bootstrap/` |
| Pins | AMI (var or SSM), image digests/tags, TLS policy, sizes |
| Tags | `providers.tf` `default_tags`, `locals.tags` |
| Benchmark targets file | `generated/benchmark-targets.json` |

**Not** managed here: Docker builds, Artillery, Grafana under `local/` and `benchmarks/`.

Instance sizes default to non-burstable `c6i.large` for EC2 and ECS and
`db.m6g.large` for RDS. That is a deliberate choice, not a placeholder: CPU
credits would otherwise vary between platforms and carry across repetitions. See
[docs/INFRASTRUCTURE.md](../docs/INFRASTRUCTURE.md#instance-type-choice-why-not-burstable).

## Makefile (from repo root)

| Target | Action |
|--------|--------|
| `make init` | `terraform init` in `terraform/` |
| `make plan` | `terraform plan` |
| `make apply` | `terraform apply` (interactive confirm) |
| `make apply NONCE=rep2` | Same, but replaces the EC2 instances, ECS hosts and tasks, and Lambda execution environments, so the next repetition starts on fresh compute and contributes new cold-start samples |
| `make destroy` | Destroy **main stack** with `-auto-approve` |
| `make validate-teardown` | Verify against AWS that nothing billable survived |
| `make output` | `terraform output` |

`make destroy` removes VPC, ALB, RDS, compute, etc. It does **not** delete the state backend (`terraform/bootstrap` S3 + DynamoDB). Re-apply with `make apply` when you need the stack again.

Run `make ecs-down` first — the capacity provider otherwise replaces instances while the teardown is removing them — and `make validate-teardown` afterwards. A successful `terraform destroy` proves the state is clean, not the account: resources created outside the stack, dropped from state, or left by a partial destroy keep billing invisibly. The validator asks AWS directly and exits non-zero while anything under the project prefix is still running.

The teardown keeps nothing: `force_destroy` on the load generator's S3 bucket, `skip_final_snapshot` on RDS, a zero-day recovery window on secrets, and `force_delete` on the ECR repositories, so the next session needs `make push-images` again.

`make loadgen-<suite>` already copies each run's six artifacts (a `.json` and a `.log` per platform) into `benchmarks/suites/<suite>/artillery/logs/` before it exits, so a completed run is on disk and survives the destroy. Note that `make loadgen-sync` moves the other way — it stages the suites *onto* the generator — so it is not the command that rescues results. What does not survive is a run whose download failed; `make validate-teardown` warns while the bucket still holds objects, which is why it is worth running before the destroy as well as after.

## Apply order

### 1. State backend (once)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=YOUR_UNIQUE_BUCKET"
```

Then create `terraform/backend.tf` from the template and fill it in with the
`backend_config` output above:

```bash
cd ..
cp backend.tf.example backend.tf
$EDITOR backend.tf
terraform init -migrate-state
```

`backend.tf` is gitignored because the bucket name is globally unique and
normally embeds an AWS account id. `backend.tf.example` is the tracked
template, so a fresh clone has no backend until you create the file.

### 2. Core stack

Creates network, security groups, ECR, secrets, IAM, ALB, log groups. RDS defaults on (`enable_rds`).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# set domain_name / route53_zone_id if you want ACM HTTPS
terraform init
terraform plan
terraform apply
```

Without domain settings the ALB is HTTP only.

### 3. Images

| Image | Dockerfile | Default tag |
|-------|------------|-------------|
| EC2 / ECS | `apps/*/Dockerfile` | `latest` |
| Lambda | `apps/*/Dockerfile.lambda` | `lambda` |

From repo root (Docker + AWS CLI; on Windows use Git Bash / WSL):

```bash
make push-images
# or: ./scripts/push-ecr.sh
```


Pin digests in `tfvars` after the first push. Details: [docs/DEPLOY.md](../docs/DEPLOY.md).

### 4. Compute

After images exist:

```hcl
enable_ec2    = true
enable_ecs    = true
enable_lambda = true
```

Empty `ec2_ami_id` / `ecs_ami_id` resolve via SSM. Pin AMI ids for stable runs.

## Deploy IAM

- Attach `iam_deploy_policy_arn` to SSO or CI.
- Or `create_deploy_role = true` with trusted principal ARNs.

Runtime: EC2 instance profile, ECS execution + task (+ container instance), Lambda per app.

## Outputs for benchmarks

| Output | Use |
|--------|-----|
| `alb_dns_name`, `public_hostnames` | Artillery / Prometheus (EC2, ECS) |
| `lambda_function_urls` | Artillery / Prometheus (Lambda) |
| `ecr_repository_urls` | `docker push` |
| `rds_address` | AniLove DB host |
| `benchmark_targets_file` | `generated/benchmark-targets.json` |
| `loadgen_instance_id` | SSM target for `make loadgen-sync` and `make loadgen-*` |
| `loadgen_bucket` | Where the generator uploads its Artillery reports |

Fill:

- [benchmarks/docs/ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md)
- [benchmarks/docs/PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md)

## Layout

```text
terraform/
  versions.tf providers.tf variables.tf locals.tf main.tf outputs.tf
  terraform.tfvars.example
  bootstrap/
  modules/
  generated/          # gitignored
```
