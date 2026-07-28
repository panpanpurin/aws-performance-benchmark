# Local Docker path: apps + metrics + Artillery

Local stack for reproducibility. Not a substitute for AWS EC2/ECS/Lambda comparison runs.

```text
Artillery (host)
    |  load
    v
Apps in Docker  --/metrics-->  Prometheus  -->  Grafana
    ^
    |  publish-metrics plugin
Artillery  ------------------>  Pushgateway
```

---

## Prerequisites

- Docker Desktop with **Compose v2.20+** (this stack and root wrapper use `include`)
- Node.js + npm (for Artillery on the host)

---

## 1. Start stack

**From repo root** (wrapper `docker-compose.yml` -> this folder):

```bash
docker compose up -d --build
# or: make local-up
docker compose ps
```

**Or from this folder**:

```bash
cd local
docker compose up -d --build
docker compose ps
```

| Service | URL |
|---------|-----|
| AniLove | http://localhost:3000/health |
| CSV Processor | http://localhost:8000/health |
| Thumbnail | http://localhost:3001/health |
| Prometheus | http://localhost:9090/targets |
| Grafana | http://localhost:3002 (user `admin` / password `admin`) |
| Pushgateway ECS / EC2 / Lambda | `:9092` / `:9093` / `:9094` |

**Local defaults for reproducibility:** Grafana `admin`/`admin` and AniLove `JWT_SECRET=local-dev-secret-change-me` are for reproducibility. Do not use them on public or production systems. AWS suites use Grafana `admin`/`123` on their own ports (see [benchmarks/docs/PORTS.md](../benchmarks/docs/PORTS.md)).

Stop:

```bash
# from repo root
docker compose down
# or: make local-down
docker compose down -v   # also wipe DB + metrics volumes
```

---

## 2. Run Artillery (local targets)

```bash
cd local/artillery
npm install

# Windows
run-local.bat
run-local.bat anilove
run-local.bat csv
run-local.bat thumbnail

# Linux / macOS
chmod +x run-local.sh
./run-local.sh
./run-local.sh anilove
```

Or:

```bash
make local-test
# or: npm run test:all  (from local/artillery)
```

Phases are short (~2-3 minutes per app) for local use.
Cloud suites under `benchmarks/<app>/artillery/` remain for AWS runs.

| Test file | Target |
|-----------|--------|
| `test-anilove-local.yml` | `http://localhost:3000` |
| `test-csv-local.yml` | `http://localhost:8000` |
| `test-thumbnail-local.yml` | `http://localhost:3001` |

Fixtures live under `local/artillery/fixtures/` (`pokes.csv`, `sample.jpg`).

Load metrics push to `http://localhost:9093` (local EC2 pushgateway slot).

---

## 3. Verify metrics

1. Open Prometheus -> **Status -> Targets** (apps and pushgateways should be **UP**).
2. Run a short Artillery test.
3. In Prometheus, try:
   - `app_total_execution_time_seconds_count`
   - `up{job="anilove-local"}`
4. Grafana -> Explore -> Prometheus datasource (pre-provisioned).

---

## Layout

```text
local/
├── docker-compose.yml      # apps + postgres + metrics
├── prometheus.yml
├── grafana/provisioning/
├── artillery/              # localhost load tests
└── README.md
```

| Container | Role |
|-----------|------|
| `postgres` | AniLove DB (`anilove` / `anilove` / `anilove`) |
| `anilove` | REST API (`DB_SSL=false`) |
| `csv-processor` | FastAPI CSV |
| `thumbnail-generator` | Sharp thumbnails |
| `prometheus` | Scrapes apps + pushgateways |
| `grafana` | Dashboards |
| `pushgateway-*` | Artillery publish-metrics |

App build contexts: `../apps/anilove`, `../apps/csv-processor`, `../apps/thumbnail-generator`.

---

## Interaction with AWS benchmark suites

Local host ports match the **AniLove** suite range:

| Service | Local / AniLove | CSV suite | Thumbnail suite |
|---------|-----------------|-----------|-----------------|
| Prometheus | 9090 | 9190 | 9290 |
| Grafana | 3002 | 3102 | 3202 |
| Pushgateways | 9092-9094 | 9192-9194 | 9292-9294 |

| Combination | OK? |
|-------------|-----|
| Local alone | Yes |
| Local + `benchmarks/suites/anilove` | No (port clash) |
| Local + `benchmarks/suites/csv-processor` | Yes |
| Local + `benchmarks/suites/thumbnail-generator` | Yes |
| All three AWS suites (no local) | Yes |

See [benchmarks/docs/PORTS.md](../benchmarks/docs/PORTS.md).

---

## Notes

- **SSL / RDS:** This compose sets `DB_SSL=false` for the bundled Postgres. On AWS RDS, TLS remains enabled by default. Use `DB_SCHEMA=ec2|ecs|lambda` for isolation on a shared database.
- **Cloud tests:** `make bench-*` and `make artillery-*`, or `benchmarks/<app>/artillery/run-parallel.bat`.
