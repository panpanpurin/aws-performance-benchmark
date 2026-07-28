# Applications

Unified workloads for the AWS performance benchmark (one codebase each: EC2 / ECS / Lambda).

| App | Path | Port | Role | Dominant bound |
|-----|------|------|------|----------------|
| AniLove | [`anilove/`](./anilove) | 3000 | REST API + PostgreSQL | I/O / database |
| CSV Processor | [`csv-processor/`](./csv-processor) | 8000 | CSV filter / aggregate | CPU + memory |
| Thumbnail | [`thumbnail-generator/`](./thumbnail-generator) | 3001 | Image resize (Sharp) | CPU + memory peaks |

Workload characteristics: [docs/WORKLOADS.md](../docs/WORKLOADS.md).

Each folder has `Dockerfile` (long-running) and `Dockerfile.lambda`.

- Local stack: [`local/docker-compose.yml`](../local/docker-compose.yml) (`make local-up`).
- AWS deploy matrix: [`docs/DEPLOY.md`](../docs/DEPLOY.md).
- Infrastructure: [`docs/INFRASTRUCTURE.md`](../docs/INFRASTRUCTURE.md), [`terraform/`](../terraform/).
- Load tests: [`benchmarks/suites/`](../benchmarks/suites/). Ports: [`benchmarks/docs/PORTS.md`](../benchmarks/docs/PORTS.md).
