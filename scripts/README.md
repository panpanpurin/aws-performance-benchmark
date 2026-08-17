# Scripts (bash + Node only)

All automation lives here or under `benchmarks/scripts/`.

On Windows use **Git Bash** or **WSL**.

| Script | Purpose |
|--------|---------|
| `check-prereqs.sh` | Verify aws, docker, terraform, node, bash |
| `validate-terraform.sh` | Pre-apply: fmt, validate, backend wiring, tfvars, ECR images vs `enable_*` |
| `validate-benchmark-config.sh` | Pre-run: Artillery targets/Host headers/pushgateway ports, Prometheus jobs, compose ports |
| `validate-aws-state.sh` | Post-apply: target-group health, ECS counts, EC2 status checks, Lambda, RDS |
| `validate-fairness.sh` | Only-compute-varies: shared metric names, 1-vCPU pins, deployed specs, live `/metrics` |
| `push-ecr.sh` | Build and push app images to ECR; pins every digest in `terraform/image-digests.auto.tfvars` |
| `run-manifest.sh` | Snapshot git SHA, AMIs, image digests and config next to a run's logs |
| `sync-artillery-targets.sh` | Fill Artillery and Prometheus targets from `terraform/generated/benchmark-targets.json` |
| `health-check.sh` | `/health` for ALB hosts + Lambda URLs |
| `ecs-scale.sh` | Scale ECS services and ASG (`up` / `down` / `status`) |
| `metrics-proxy.js` | Host proxy for EC2/ECS scrapes on an HTTP-only ALB; exits when a domain is set |

Shared Artillery runner: `benchmarks/scripts/run-parallel.sh`.

## Typical flow

```bash
make check
make validate-tf     # before apply
make apply
make push-images
make sync-targets
make health
make ecs-up
make validate-aws       # every target healthy, not just one
make validate-fairness  # only the compute model varies
make bench-anilove
make metrics-proxy      # HTTP-only stacks; no-op with a domain
make validate-bench     # before the 17.5 minute run
make artillery-anilove
make ecs-down           # or make destroy when done
```

`validate-terraform.sh` and `validate-fairness.sh` skip their AWS checks when no
credentials resolve; pass `--offline` to skip them deliberately.
`validate-fairness.sh --no-scrape` keeps the deployed checks but skips the live
`/metrics` pull. All four are read-only.

## Make aliases

See `make help` at the repo root.
