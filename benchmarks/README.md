# Benchmarks

AWS observability and Artillery load tests per workload.

```text
benchmarks/
├── docs/                 # ports, Prometheus and Artillery targets
├── scripts/              # shared run-parallel.sh / .ps1
├── stack/                # shared Prometheus + Grafana + pushgateways
└── suites/
    ├── anilove/
    ├── csv-processor/
    └── thumbnail-generator/
```

| Path | Role |
|------|------|
| `docs/` | Ports and how to fill targets |
| `scripts/` | Shared parallel Artillery runner |
| `stack/` | Shared metrics containers |
| `suites/<app>/` | Compose ports, `prometheus.yml`, dashboard, Artillery |

Each suite:

1. Sets `name: <app>-benchmark`
2. Includes `../../stack/docker-compose.yml`
3. Maps suite host ports ([PORTS.md](./docs/PORTS.md))
4. Mounts its own `prometheus.yml`

App scrape targets start empty ([PROMETHEUS-TARGETS.md](./docs/PROMETHEUS-TARGETS.md)).

Artillery `target` starts as `https://REPLACE_ME` ([ARTILLERY-TARGETS.md](./docs/ARTILLERY-TARGETS.md)).

## Ports

| Suite | Prometheus | Grafana | Pushgateways (ECS / EC2 / Lambda) |
|-------|------------|---------|-----------------------------------|
| AniLove | 9090 | 3002 | 9092 / 9093 / 9094 |
| CSV | 9190 | 3102 | 9192 / 9193 / 9194 |
| Thumbnail | 9290 | 3202 | 9292 / 9293 / 9294 |

Grafana (AWS suites): `admin` / `123`.

## Quick start

```bash
make bench-anilove
# set Artillery targets first (terraform outputs)
make artillery-anilove
```

All three stacks:

```bash
make bench-anilove bench-csv bench-thumbnail
```

| Suite | Folder | Grafana |
|-------|--------|---------|
| AniLove | `suites/anilove/` | http://localhost:3002 |
| CSV | `suites/csv-processor/` | http://localhost:3102 |
| Thumbnail | `suites/thumbnail-generator/` | http://localhost:3202 |

CSV and Thumbnail Artillery need `form-data` once:

```bash
cd suites/csv-processor/artillery && npm install
cd suites/thumbnail-generator/artillery && npm install
```

Artillery CLI: `npx artillery@2.0.23` (no global install).

| Related | Link |
|---------|------|
| Apps | [apps/](../apps/) |
| Parallel guide | [PARALLEL-BENCHMARK.md](../docs/PARALLEL-BENCHMARK.md) |
| Terraform outputs | [terraform/README.md](../terraform/README.md) |
