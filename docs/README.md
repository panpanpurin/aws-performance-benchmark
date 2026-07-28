# Documentation

| Doc | Topic |
|-----|--------|
| [INFRASTRUCTURE.md](./INFRASTRUCTURE.md) | Target AWS infra (VPC, one ALB, one ECS cluster, Lambda Function URL, single RDS) |
| [IAM.md](./IAM.md) | Deploy path and runtime IAM roles |
| [../terraform/README.md](../terraform/README.md) | Terraform apply guide and module map |
| [WORKLOADS.md](./WORKLOADS.md) | CPU / memory / I/O-bound characteristics of each app |
| [DEPLOY.md](./DEPLOY.md) | Packaging, env vars, RDS/TLS/schemas |
| [PARALLEL-BENCHMARK.md](./PARALLEL-BENCHMARK.md) | Parallel Artillery for side-by-side Grafana charts |
| [../benchmarks/docs/PORTS.md](../benchmarks/docs/PORTS.md) | Host ports so multiple benchmark suites can run together |
| [../benchmarks/docs/PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md) | Empty app scrape targets and how to fill them |
| [../benchmarks/docs/ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md) | Artillery base URLs (`REPLACE_ME` until set) |

Related paths:

| Path | Topic |
|------|--------|
| [../local/README.md](../local/README.md) | Local Docker path (apps + metrics + Artillery) |
| [../benchmarks/README.md](../benchmarks/README.md) | AWS metrics suites + shared stack |
| [../apps/](../apps/) | Application source (one codebase each) |
| [../Makefile](../Makefile) | Common commands (`make help`) |
