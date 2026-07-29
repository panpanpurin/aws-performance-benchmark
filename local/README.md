# Local Docker path

Apps + metrics + Artillery on your machine. Not a substitute for AWS EC2 / ECS / Lambda runs.

```text
Artillery (host)
    |  load
    v
Apps in Docker  --/metrics-->  Prometheus  -->  Grafana
    ^
    |  publish-metrics plugin
Artillery  ------------------>  Pushgateway
```

## Prerequisites

- Docker Desktop with Compose **v2.20+** (`include` in compose files)
- Node.js and npm (Artillery on the host)

## 1. Start stack

From repo root:

```bash
make local-up
docker compose ps
```

From this folder:

```bash
cd local
docker compose up -d --build
```

| Service | URL |
|---------|-----|
| AniLove | http://localhost:3000/health |
| CSV Processor | http://localhost:8000/health |
| Thumbnail | http://localhost:3001/health |
| Prometheus | http://localhost:9090/targets |
| Grafana | http://localhost:3002 (`admin` / `admin`) |
| Pushgateway ECS / EC2 / Lambda | `:9092` / `:9093` / `:9094` |

Local defaults (Grafana password, sample JWT) are for local use only. AWS suites use Grafana `admin` / `123` on other ports ([PORTS.md](../benchmarks/docs/PORTS.md)).

Stop:

```bash
make local-down
# wipe volumes: docker compose down -v
```

## 2. Artillery (localhost)

```bash
make local-test
# or:
cd local/artillery && npm install && npm run test:all
```

Windows: `run-local.bat` or `run-local.bat anilove`.

Linux / macOS: `./run-local.sh`.

Phases are short (about 2 to 3 minutes per app).

| Test file | Target |
|-----------|--------|
| `test-anilove-local.yml` | http://localhost:3000 |
| `test-csv-local.yml` | http://localhost:8000 |
| `test-thumbnail-local.yml` | http://localhost:3001 |

Fixtures: `local/artillery/fixtures/` (`pokes.csv`, `sample.jpg`).

Load metrics push to the local EC2 pushgateway slot (`:9093`).

AWS load tests: `benchmarks/suites/<app>/artillery/` ([ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md)).

## 3. Verify metrics

1. Prometheus → Status → Targets (apps and pushgateways **UP**).
2. Run a short Artillery test.
3. Query e.g. `app_total_execution_time_seconds_count` or `up{job="anilove-local"}`.
4. Grafana Explore (Prometheus datasource is pre provisioned).

## Layout

```text
local/
├── docker-compose.yml
├── prometheus.yml
├── grafana/provisioning/
└── artillery/
```

| Container | Role |
|-----------|------|
| `postgres` | AniLove DB |
| `anilove` / `csv-processor` / `thumbnail-generator` | Apps (`DB_SSL=false` for AniLove) |
| `prometheus` / `grafana` | Metrics UI |
| `pushgateway-*` | Artillery publish metrics |

Build contexts: `../apps/*`.

## Ports vs AWS suites

Local uses the **AniLove** suite range (9090, 3002, 9092 to 9094).

| Combination | OK? |
|-------------|-----|
| Local alone | Yes |
| Local + `benchmarks/suites/anilove` | No (port clash) |
| Local + CSV or Thumbnail suite | Yes |
| All three AWS suites (no local) | Yes |

Full table: [PORTS.md](../benchmarks/docs/PORTS.md).

## Notes

- Local Postgres: `DB_SSL=false`. AWS RDS: TLS on by default; use `DB_SCHEMA=ec2|ecs|lambda` on shared DB.
- AWS metrics + load: `make bench-*` / `make artillery-*` or suite `artillery/run-parallel.*`.
- Terraform: [terraform/README.md](../terraform/README.md).
