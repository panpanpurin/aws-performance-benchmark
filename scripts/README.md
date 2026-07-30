# Scripts (bash + Node only)

All automation lives here or under `benchmarks/scripts/`. No PowerShell (`.ps1`).

On Windows use **Git Bash** or **WSL**.

| Script | Purpose |
|--------|---------|
| `check-prereqs.sh` | Verify aws, docker, terraform, node, bash |
| `push-ecr.sh` | Build and push app images to ECR |
| `sync-artillery-targets.sh` | Fill Artillery YAML from `terraform/generated/benchmark-targets.json` |
| `health-check.sh` | HTTP health for ALB hosts + Lambda URLs |
| `ecs-scale.sh` | Scale ECS services and ASG (`up` / `down` / `status`) |
| `anilove-metrics-proxy.js` | Host proxy for Prometheus scrapes of EC2/ECS via ALB |

Shared Artillery runner: `benchmarks/scripts/run-parallel.sh`.

## Typical flow

```bash
make check
make apply
make push-images
make sync-targets
make health
make ecs-up
make bench-anilove
make metrics-proxy   # leave running
make artillery-anilove
make ecs-down        # or make destroy when done
```

## Make aliases

See `make help` at the repo root.
