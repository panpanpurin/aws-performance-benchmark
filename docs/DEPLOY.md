# Deploy matrix: EC2 / ECS / Lambda

Packaging and configuration for each compute model. Application logic is shared; entrypoint, image base, and runtime env differ by target.

| Related | Link |
|---------|------|
| Apps | [apps/](../apps/) |
| Infrastructure | [INFRASTRUCTURE.md](./INFRASTRUCTURE.md) |
| Terraform | [terraform/README.md](../terraform/README.md) |
| Workloads | [WORKLOADS.md](./WORKLOADS.md) |

**Region:** ap-northeast-1 (Tokyo).

| App | Dominant bound |
|-----|----------------|
| AniLove | I/O / database |
| CSV Processor | CPU + memory |
| Thumbnail Generator | CPU + memory peaks |

## Quick matrix

| App | Port | EC2 / ECS entry | Lambda handler | Image (EC2/ECS) | Image (Lambda) |
|-----|------|-----------------|----------------|-----------------|----------------|
| **AniLove** | 3000 | `npm start` → `server.js` | `index.handler` | `Dockerfile` | `Dockerfile.lambda` |
| **CSV Processor** | 8000 | `uvicorn app.main:app` | `app.main.handler` | `Dockerfile` | `Dockerfile.lambda` |
| **Thumbnail** | 3001 | `npm start` → `server.js` | `index.handler` | `Dockerfile` | `Dockerfile.lambda` |

Build **one** image from `Dockerfile` for EC2 and ECS. Build a **separate** image from `Dockerfile.lambda` for Lambda.

| Platform | Default sizing (Terraform) |
|----------|----------------------------|
| EC2 | `c6i.large` host; container capped at 1 vCPU / 1024 MiB |
| ECS task | 1024 CPU / 1024 MiB (on `c6i.large` capacity) |
| Lambda | 1769 MB memory (one full vCPU), 1024 MB ephemeral, 30 s timeout |

## Environment variables

### AniLove (`apps/anilove/`)

| Variable | Required | Notes |
|----------|----------|--------|
| `DB_NAME` | yes | Database name (Terraform default `anilove`) |
| `DB_USER` | yes | Master user (Terraform default `anilove`) |
| `DB_PASSWORD` | yes | From Secrets Manager / Terraform |
| `DB_HOST` | yes | RDS address |
| `DB_PORT` | yes | `5432` |
| `DB_SSL` | no | Default on; set `false` only for local non TLS Postgres |
| `DB_SSL_REJECT_UNAUTHORIZED` | no | Default `false` |
| `DB_SCHEMA` | yes* | `ec2` / `ecs` / `lambda` per platform |
| `JWT_SECRET` | yes | From Secrets Manager |
| `PORT` | no | Default `3000` (long running) |
| `NODE_ENV` | no | e.g. `production` |
| `SERVICE_NAME` | no | Prometheus label |

\* Distinct schemas so platforms do not overwrite each other’s tables on the shared RDS.

| Choice | Why |
|--------|-----|
| One RDS | DB capacity is a controlled constant |
| Schemas `ec2` / `ecs` / `lambda` | Data isolation without three engines |
| Same VPC and SG rules | No network path bias |

Caveats:

1. Parallel platform load shares RDS CPU and IOPS.
2. Keep pools reasonable (`DB_POOL_MAX`).
3. Clear only the active schema: `DB_SCHEMA=ec2 node cleanDB.js`.
4. For platform charts, run EC2 + ECS + Lambda Artillery together ([PARALLEL-BENCHMARK.md](./PARALLEL-BENCHMARK.md)).

Example (after Terraform apply; prefer secrets injection over plain `.env` on AWS):

```env
DB_NAME=anilove
DB_USER=anilove
DB_PASSWORD=<from-secrets>
DB_HOST=<rds-address>
DB_PORT=5432
DB_SSL=true
DB_SCHEMA=ec2
JWT_SECRET=<from-secrets>
PORT=3000
NODE_ENV=production
SERVICE_NAME=anilove
```

ECS: `DB_SCHEMA=ecs`. Lambda: `DB_SCHEMA=lambda`.

Edge: one ALB for EC2 and ECS; Lambda uses Function URL HTTPS only.

### CSV Processor

| Variable | Notes |
|----------|--------|
| `SERVICE_NAME` | Prometheus label (optional) |
| `ENVIRONMENT` | Default `production` |
| `OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS` | Set to `1` in the image |

### Thumbnail Generator

| Variable | Notes |
|----------|--------|
| `PORT` | Default `3001` |
| `NODE_ENV` | e.g. `production` |
| `SERVICE_NAME` | Prometheus label (optional) |

## Build images

From repo root:

```bash
docker build -t anilove:ec2-ecs -f apps/anilove/Dockerfile apps/anilove
docker build -t anilove:lambda  -f apps/anilove/Dockerfile.lambda apps/anilove

docker build -t csv-processor:ec2-ecs -f apps/csv-processor/Dockerfile apps/csv-processor
docker build -t csv-processor:lambda  -f apps/csv-processor/Dockerfile.lambda apps/csv-processor

docker build -t thumbnail-generator:ec2-ecs -f apps/thumbnail-generator/Dockerfile apps/thumbnail-generator
docker build -t thumbnail-generator:lambda  -f apps/thumbnail-generator/Dockerfile.lambda apps/thumbnail-generator
```

### Push to ECR (automated)

After core `terraform apply` (ECR repos exist), from the **repo root**:

```bash
# Docker Desktop running, AWS CLI configured (Git Bash / WSL on Windows)
make push-images
# or: ./scripts/push-ecr.sh [all|anilove|csv|thumbnail]
```

After images are in ECR and compute is applied, refresh Artillery + scrape configs from Terraform outputs:

```bash
make sync-targets
make health
```

See [scripts/README.md](../scripts/README.md).

### Smoke run locally

```bash
docker run -d -p 3000:3000 --env-file apps/anilove/.env anilove:ec2-ecs
docker run -d -p 8000:8000 csv-processor:ec2-ecs
docker run -d -p 3001:3001 thumbnail-generator:ec2-ecs
```

## Metrics and load tests

| Piece | Path |
|-------|------|
| Shared stack | [benchmarks/stack/](../benchmarks/stack/) |
| Per app suite | `benchmarks/suites/<app>/` |
| Ports | [PORTS.md](../benchmarks/docs/PORTS.md) |
| Prometheus targets | [PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md) |
| Artillery targets | [ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md) |

App and node exporter scrape targets start empty. Pushgateway jobs use Compose service names.

| Workload | Suite | Artillery `service` label |
|----------|-------|---------------------------|
| AniLove | `suites/anilove/` | `anilove-service` |
| CSV | `suites/csv-processor/` | `csv-processor-service` |
| Thumbnail | `suites/thumbnail-generator/` | `thumbnail-service` |

| Suite | Prometheus | Grafana | Pushgateways (ECS / EC2 / Lambda) |
|-------|------------|---------|-----------------------------------|
| AniLove | 9090 | 3002 | 9092 / 9093 / 9094 |
| CSV | 9190 | 3102 | 9192 / 9193 / 9194 |
| Thumbnail | 9290 | 3202 | 9292 / 9293 / 9294 |

```bash
make bench-anilove
make artillery-anilove
```

## Local Docker path

```bash
make local-up
make local-test
```

Local ports match the AniLove suite range. Do not run `benchmarks/suites/anilove` while local is up. Details: [local/README.md](../local/README.md).

## Checklist before a benchmark run

1. Region is **ap-northeast-1** for all platforms.
2. AniLove: one RDS and distinct `DB_SCHEMA` values.
3. Images built from `apps/<name>/` and pushed to ECR.
4. Compute enabled in Terraform when ready (`enable_*`).
5. Prometheus app targets filled for the suite under test.
6. Artillery `target` set (not `https://REPLACE_ME`).
7. Pushgateway ports match the suite ([PORTS.md](../benchmarks/docs/PORTS.md)).
8. Report Lambda cold and warm separately when relevant.
9. Use the correct Grafana port per suite if several run at once.
