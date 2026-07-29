# Documentation

## Reading order

1. [WORKLOADS.md](./WORKLOADS.md): what each app measures
2. [INFRASTRUCTURE.md](./INFRASTRUCTURE.md): AWS layout (Tokyo, one ALB, one RDS)
3. [terraform/README.md](../terraform/README.md): apply the stack
4. [DEPLOY.md](./DEPLOY.md): images, env vars, metrics wiring
5. [PARALLEL-BENCHMARK.md](./PARALLEL-BENCHMARK.md): Artillery for side by side charts

## In this folder

| Doc | Topic |
|-----|--------|
| [INFRASTRUCTURE.md](./INFRASTRUCTURE.md) | VPC, one ALB, one ECS cluster, Lambda Function URL, single RDS |
| [IAM.md](./IAM.md) | Deploy path and runtime roles |
| [DEPLOY.md](./DEPLOY.md) | Packaging, env vars, RDS, TLS, schemas, build commands |
| [WORKLOADS.md](./WORKLOADS.md) | CPU, memory, and I/O profile of each app |
| [PARALLEL-BENCHMARK.md](./PARALLEL-BENCHMARK.md) | Parallel Artillery (EC2 + ECS + Lambda) |

## Elsewhere

| Path | Topic |
|------|--------|
| [../terraform/README.md](../terraform/README.md) | Terraform apply order, modules, outputs |
| [../local/README.md](../local/README.md) | Local Docker (apps + metrics + Artillery) |
| [../benchmarks/README.md](../benchmarks/README.md) | AWS metrics suites |
| [../benchmarks/docs/PORTS.md](../benchmarks/docs/PORTS.md) | Host ports for concurrent suites |
| [../benchmarks/docs/PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md) | Fill empty scrape targets |
| [../benchmarks/docs/ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md) | Set Artillery `target` URLs |
| [../apps/](../apps/) | Application source |
| [../Makefile](../Makefile) | `make help` |
