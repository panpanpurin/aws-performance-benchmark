# AWS Performance Benchmark

Project comparing **EC2**, **ECS on EC2**, and **AWS Lambda** across three instrumented workloads.

> Compare **platforms**, not different app forks: one codebase per app, dual entrypoints, dual Docker images.

---

## Prerequisites

- Docker Desktop with **Compose v2.20+** (root and suite stacks use `include`)
- Node.js + npm (Artillery via `npx`; local load tests)

## Start here

```bash
make help                 # list common commands
make local-up             # apps + metrics on Docker
make local-test           # Artillery vs localhost
make bench-anilove        # Prometheus/Grafana for AniLove on AWS
make artillery-anilove    # EC2+ECS+Lambda load at once (bash)
```

Before AWS Artillery runs, set each suite `target` (currently `https://REPLACE_ME`). See [benchmarks/docs/ARTILLERY-TARGETS.md](./benchmarks/docs/ARTILLERY-TARGETS.md).

| Goal | Command / link |
|------|----------------|
| **Local path** | `make local-up` then `make local-test` |
| **AWS load + charts (one suite)** | `make bench-anilove` then `make artillery-anilove` |
| **All three suites together** | `make bench-anilove bench-csv bench-thumbnail` then artillery targets (see ports) |
| **Workload bounds (CPU / memory / I/O)** | [docs/WORKLOADS.md](./docs/WORKLOADS.md) |
| **AWS infrastructure** | [docs/INFRASTRUCTURE.md](./docs/INFRASTRUCTURE.md) |
| **IAM** | [docs/IAM.md](./docs/IAM.md) |
| **Terraform (AWS)** | [terraform/README.md](./terraform/README.md) |
| **Deploy / env vars** | [docs/DEPLOY.md](./docs/DEPLOY.md) |
| **Parallel Artillery** | [docs/PARALLEL-BENCHMARK.md](./docs/PARALLEL-BENCHMARK.md) |
| **Suite host ports** | [benchmarks/docs/PORTS.md](./benchmarks/docs/PORTS.md) |
| **All docs** | [docs/README.md](./docs/README.md) |

---

## Repository layout

```text
apps/                         # one codebase per workload (EC2 / ECS / Lambda)
  anilove/
  csv-processor/
  thumbnail-generator/

benchmarks/                   # AWS metrics suites + Artillery
  docs/                       # ports, Prometheus and Artillery targets
  scripts/                    # shared run-parallel runners
  stack/                      # shared Prometheus + Grafana + pushgateways
  suites/
    anilove/
    csv-processor/
    thumbnail-generator/

local/                        # local apps + metrics + Artillery
  docker-compose.yml
  artillery/

terraform/                    # AWS infrastructure (Tokyo default)
  bootstrap/                  # remote state bucket + lock table
  modules/

docs/                         # deploy, workloads, IAM, infrastructure
docker-compose.yml            # includes local/
Makefile
```

### Apps (`apps/`)

| Folder | Workload | Stack | Entrypoints |
|--------|----------|-------|-------------|
| [`apps/anilove`](./apps/anilove) | REST + PostgreSQL | Node / Express / Sequelize | `server.js` / `index.handler` |
| [`apps/csv-processor`](./apps/csv-processor) | CSV filter / aggregate | Python / FastAPI / pandas | `uvicorn` / `app.main.handler` |
| [`apps/thumbnail-generator`](./apps/thumbnail-generator) | Image resize | Node / Express / Sharp | `server.js` / `index.handler` |

Each app: `Dockerfile` (EC2/ECS) + `Dockerfile.lambda` + `/metrics`.

| App | Dominant bound |
|-----|----------------|
| AniLove | I/O / database |
| CSV Processor | CPU + memory |
| Thumbnail Generator | CPU + memory peaks |

Details: [docs/WORKLOADS.md](./docs/WORKLOADS.md).

### Benchmarks (`benchmarks/`)

| Folder | Role |
|--------|------|
| [`benchmarks/stack`](./benchmarks/stack) | Shared metrics stack (included by each suite) |
| [`benchmarks/suites/anilove`](./benchmarks/suites/anilove) | AniLove scrape targets + Artillery + dashboard |
| [`benchmarks/suites/csv-processor`](./benchmarks/suites/csv-processor) | CSV suite |
| [`benchmarks/suites/thumbnail-generator`](./benchmarks/suites/thumbnail-generator) | Thumbnail suite |
| [`benchmarks/docs/PORTS.md`](./benchmarks/docs/PORTS.md) | Host ports for concurrent suites |
| [`benchmarks/docs/PROMETHEUS-TARGETS.md`](./benchmarks/docs/PROMETHEUS-TARGETS.md) | Empty scrape targets to fill later |
| [`benchmarks/docs/ARTILLERY-TARGETS.md`](./benchmarks/docs/ARTILLERY-TARGETS.md) | Artillery `target` URLs (`REPLACE_ME` until set) |

Suites use **different host ports** and can run together:

| Suite | Prometheus | Grafana | Pushgateways (ECS/EC2/Lambda) |
|-------|------------|---------|-------------------------------|
| AniLove | 9090 | 3002 | 9092 / 9093 / 9094 |
| CSV | 9190 | 3102 | 9192 / 9193 / 9194 |
| Thumbnail | 9290 | 3202 | 9292 / 9293 / 9294 |

### Local

| URL | Service |
|-----|---------|
| http://localhost:3000 | AniLove |
| http://localhost:8000 | CSV |
| http://localhost:3001 | Thumbnail |
| http://localhost:9090 | Prometheus |
| http://localhost:3002 | Grafana (`admin`/`admin`) |

Local stack shares the AniLove port range. Do not start `benchmarks/suites/anilove` while local is up. CSV and Thumbnail suites can run alongside local.

Local Grafana/JWT defaults (`admin`/`admin`, sample JWT secret) are local-only. Do not use them in production. Details: [local/README.md](./local/README.md).

---

## License

MIT - see [LICENSE](./LICENSE).
