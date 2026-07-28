# Deploy matrix: EC2 / ECS / Lambda

Packaging and configuration for each compute model.
Application logic is shared; entrypoint, image base, and runtime env differ by target.

Applications live under [`apps/`](../apps/).

Workload bounds (CPU / memory / I/O): [WORKLOADS.md](./WORKLOADS.md).

| App | Dominant bound |
|-----|----------------|
| AniLove | I/O / database |
| CSV Processor | CPU + memory |
| Thumbnail Generator | CPU + memory peaks |

---

## Quick matrix

| App | Port (long-running) | EC2 / ECS entry | Lambda handler | Image (EC2/ECS) | Image (Lambda) |
|-----|---------------------|-----------------|----------------|-----------------|----------------|
| **AniLove** | `3000` | `npm start` -> `server.js` | `index.handler` | `Dockerfile` | `Dockerfile.lambda` |
| **CSV Processor** | `8000` | `uvicorn app.main:app` | `app.main.handler` | `Dockerfile` | `Dockerfile.lambda` |
| **Thumbnail** | `3001` | `npm start` -> `server.js` | `index.handler` | `Dockerfile` | `Dockerfile.lambda` |

**Rule:** build one image from `Dockerfile` for both EC2 and ECS. Build a separate image from `Dockerfile.lambda` for Lambda.

Suggested size parity (document the exact sizes used in the benchmark):

| Platform | Typical sizing (example) |
|----------|---------------------------|
| EC2 | `t2.micro` (1 vCPU burst, 1 GiB) |
| ECS on EC2 | Task ~1 vCPU, 1 GiB hard (e.g. on `t3.small` host) |
| Lambda | 1024 MB memory (~1 vCPU share), 1024 MB ephemeral if needed |

Region used in existing configs: **`sa-east-1`**.

---

## Environment variables

### AniLove (`apps/anilove/`)

| Variable | Required | EC2 | ECS | Lambda | Description |
|----------|----------|-----|-----|--------|-------------|
| `DB_NAME` | yes | yes | yes | yes | Shared RDS database name |
| `DB_USER` | yes | yes | yes | yes | DB user |
| `DB_PASSWORD` | yes | yes | yes | yes | DB password |
| `DB_HOST` | yes | yes | yes | yes | RDS endpoint |
| `DB_PORT` | yes | yes | yes | yes | Usually `5432` |
| `DB_SSL` | no | yes | yes | yes | TLS on by default; set `false` only for local non-TLS Postgres |
| `DB_SSL_REJECT_UNAUTHORIZED` | no | yes | yes | yes | `true` verifies CA; default `false` |
| `DB_SCHEMA` | yes* | `ec2` | `ecs` | `lambda` | Isolates tables per platform on the shared DB |
| `JWT_SECRET` | yes | yes | yes | yes | JWT signing secret |
| `PORT` | no | yes | yes | - | Default `3000` |
| `NODE_ENV` | no | yes | yes | yes | e.g. `production` |
| `SERVICE_NAME` | no | yes | yes | yes | Prometheus label |
| `AWS_LAMBDA_*` | auto | - | - | set by AWS | Used for cold-start metrics |

\* Use distinct `DB_SCHEMA` values so one platform load test does not rewrite another platform rows.

#### Shared RDS for a fairer compute comparison

A single RDS instance for AniLove on EC2, ECS, and Lambda keeps the database a controlled constant:

| Choice | Rationale |
|--------|-----------|
| Same RDS instance / DB class | DB latency and capacity stay constant; measured differences are mostly compute |
| Separate schemas (`ec2` / `ecs` / `lambda`) | Same engine with isolated tables |
| Same region as apps | Avoids extra network bias |

Caveats:

1. For Grafana comparison charts, run EC2 + ECS + Lambda Artillery in parallel. See [PARALLEL-BENCHMARK.md](./PARALLEL-BENCHMARK.md).
2. Keep connection pools reasonable (`DB_POOL_MAX`).
3. Clear only the active schema: `DB_SCHEMA=ec2 node cleanDB.js`.
4. Do not use different RDS classes per platform for a compute-only comparison.

Example (EC2 on shared RDS):

```env
DB_NAME=anilove
DB_USER=postgres
DB_PASSWORD=password
DB_HOST=rds.sa-east-1.rds.amazonaws.com
DB_PORT=5432
DB_SSL=true
DB_SSL_REJECT_UNAUTHORIZED=false
DB_SCHEMA=ec2
JWT_SECRET=secret
PORT=3000
NODE_ENV=production
SERVICE_NAME=anilove
```

ECS: `DB_SCHEMA=ecs`. Lambda: `DB_SCHEMA=lambda`.

---

### CSV Processor (`apps/csv-processor/`)

| Variable | Required | Description |
|----------|----------|-------------|
| `SERVICE_NAME` | no | Prometheus label |
| `ENVIRONMENT` | no | Default `production` |
| `OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS` | set in image | `1` for fair 1-vCPU |

---

### Thumbnail Generator (`apps/thumbnail-generator/`)

| Variable | Required | Description |
|----------|----------|-------------|
| `PORT` | no | Default `3001` |
| `NODE_ENV` | no | e.g. `production` |
| `SERVICE_NAME` | no | Prometheus labels |

---

## Build commands

From repo root:

```bash
# AniLove
docker build -t anilove:ec2-ecs -f apps/anilove/Dockerfile apps/anilove
docker build -t anilove:lambda  -f apps/anilove/Dockerfile.lambda apps/anilove

# CSV
docker build -t csv-processor:ec2-ecs -f apps/csv-processor/Dockerfile apps/csv-processor
docker build -t csv-processor:lambda  -f apps/csv-processor/Dockerfile.lambda apps/csv-processor

# Thumbnail
docker build -t thumbnail-generator:ec2-ecs -f apps/thumbnail-generator/Dockerfile apps/thumbnail-generator
docker build -t thumbnail-generator:lambda  -f apps/thumbnail-generator/Dockerfile.lambda apps/thumbnail-generator
```

### Run container locally (long-running style)

```bash
docker run -d -p 3000:3000 --env-file apps/anilove/.env anilove:ec2-ecs
docker run -d -p 8000:8000 csv-processor:ec2-ecs
docker run -d -p 3001:3001 thumbnail-generator:ec2-ecs
```

### Lambda / ECS / EC2

ECR + Function URL / task definition / host Docker. Handlers:

- AniLove / Thumbnail: `index.handler`
- CSV: `app.main.handler`

---

## Metrics and load-test wiring

Shared stack definition: [`benchmarks/stack/`](../benchmarks/stack/).
Each suite under `benchmarks/suites/<app>/` adds host port mappings, `prometheus.yml`, Artillery, and `grafana/dashboard.json`.
App and node-exporter scrape `targets` in each `prometheus.yml` are empty (`[]`) by default for later fill (manual or automation). Pushgateway targets are fixed Compose service names. See [benchmarks/docs/PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md).

| Workload | Suite | Artillery labels |
|----------|-------|------------------|
| AniLove | `benchmarks/suites/anilove/` | `service=anilove-service`, `scenario=animes-crud`, `instance=ec2\|ecs\|lambda` |
| CSV | `benchmarks/suites/csv-processor/` | `service=csv-processor-service`, `scenario=process-csv-formdata` |
| Thumbnail | `benchmarks/suites/thumbnail-generator/` | `service=thumbnail-service`, `scenario=upload-formdata` |

Layout: `benchmarks/docs/`, `benchmarks/stack/`, `benchmarks/suites/<app>/`.

### Host ports (suites can run concurrently)

| Suite | Prometheus | Grafana | Pushgateways (ECS / EC2 / Lambda) |
|-------|------------|---------|-----------------------------------|
| AniLove | 9090 | 3002 | 9092 / 9093 / 9094 |
| CSV | 9190 | 3102 | 9192 / 9193 / 9194 |
| Thumbnail | 9290 | 3202 | 9292 / 9293 / 9294 |

Full table and examples: [benchmarks/docs/PORTS.md](../benchmarks/docs/PORTS.md).

```bash
# one suite
make bench-anilove
make artillery-anilove

# or all three stacks at once
make bench-anilove
make bench-csv
make bench-thumbnail
```

---

## Local Docker path

```bash
# from repo root
docker compose up -d --build
# or: make local-up
cd local/artillery && npm install && npm run test:all
# or: make local-test
```

Local stack ports match AniLove (9090 / 3002 / 9092-9094). Do not start `benchmarks/suites/anilove` while local is up. CSV and Thumbnail suites can run alongside local.

See [../local/README.md](../local/README.md).

---

## Checklist before a benchmark run

1. Same region for all three platforms.
2. AniLove uses the same RDS plus distinct `DB_SCHEMA` values.
3. Images built from `apps/<name>/`.
4. App/node-exporter targets filled in `benchmarks/suites/<app>/prometheus.yml` (start empty) and reachable for the suite(s) under test.
5. Artillery `instance` labels and pushgateway ports match the suite ([PORTS.md](../benchmarks/docs/PORTS.md)).
6. Report Lambda cold and warm results separately.
7. If running multiple suites, use the correct Grafana/Prometheus ports for each suite.
