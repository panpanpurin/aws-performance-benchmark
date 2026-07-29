# Applications

One codebase per workload for EC2, ECS, and Lambda.

| App | Path | Port | Role | Dominant bound |
|-----|------|------|------|----------------|
| AniLove | [anilove/](./anilove) | 3000 | REST API + PostgreSQL | I/O / database |
| CSV Processor | [csv-processor/](./csv-processor) | 8000 | CSV filter / aggregate | CPU + memory |
| Thumbnail | [thumbnail-generator/](./thumbnail-generator) | 3001 | Image resize (Sharp) | CPU + memory peaks |

Workload characteristics: [docs/WORKLOADS.md](../docs/WORKLOADS.md).

Each folder has `Dockerfile` (long running) and `Dockerfile.lambda`.

| Topic | Link |
|-------|------|
| Local stack | [local/docker-compose.yml](../local/docker-compose.yml) (`make local-up`) |
| Deploy matrix | [docs/DEPLOY.md](../docs/DEPLOY.md) |
| Infrastructure | [docs/INFRASTRUCTURE.md](../docs/INFRASTRUCTURE.md) |
| Terraform | [terraform/](../terraform/) |
| Load tests | [benchmarks/suites/](../benchmarks/suites/) |
| Ports | [benchmarks/docs/PORTS.md](../benchmarks/docs/PORTS.md) |
