# Benchmarks

AWS observability and Artillery load tests for each workload.

```text
benchmarks/
├── README.md
├── docs/                          # ports + prometheus target notes
│   ├── PORTS.md
│   └── PROMETHEUS-TARGETS.md
├── scripts/                       # shared run-parallel.sh / .ps1
├── stack/                         # shared metrics stack
│   ├── docker-compose.yml
│   └── grafana/provisioning/
└── suites/                        # one folder per workload
    ├── README.md
    ├── anilove/
    │   ├── docker-compose.yml
    │   ├── prometheus.yml
    │   ├── grafana/dashboard.json
    │   └── artillery/
    ├── csv-processor/
    │   └── artillery/fixtures/    # data.csv, pokes.csv
    └── thumbnail-generator/
        └── artillery/fixtures/    # sample.jpg
```

## Layout roles

| Path | Role |
|------|------|
| `docs/` | Ports and Prometheus target conventions |
| `scripts/` | Shared parallel Artillery runner |
| `stack/` | Shared Prometheus + Grafana + pushgateways |
| `suites/<app>/` | Per-workload compose, scrape config, dashboard, Artillery |

## Shared stack (`stack/`)

Each suite compose file:

1. Sets `name: <app>-benchmark`
2. Includes `../../stack/docker-compose.yml`
3. Maps suite-specific host ports (see [docs/PORTS.md](./docs/PORTS.md))
4. Mounts `./prometheus.yml` on Prometheus

App/node-exporter targets start empty: [docs/PROMETHEUS-TARGETS.md](./docs/PROMETHEUS-TARGETS.md).

## Concurrent suites

| Suite | Prometheus | Grafana | Pushgateways (ECS / EC2 / Lambda) |
|-------|------------|---------|-----------------------------------|
| AniLove | 9090 | 3002 | 9092 / 9093 / 9094 |
| CSV | 9190 | 3102 | 9192 / 9193 / 9194 |
| Thumbnail | 9290 | 3202 | 9292 / 9293 / 9294 |

## Quick start

```bash
make bench-anilove
make artillery-anilove
```

All three stacks:

```bash
make bench-anilove bench-csv bench-thumbnail
make artillery-anilove   # optional concurrent with the others
```

| Suite | Folder | Grafana |
|-------|--------|---------|
| AniLove | `suites/anilove/` | http://localhost:3002 |
| CSV | `suites/csv-processor/` | http://localhost:3102 |
| Thumbnail | `suites/thumbnail-generator/` | http://localhost:3202 |

### Artillery npm deps

CSV and Thumbnail processors need `form-data`. Install only if missing:

```bash
cd suites/csv-processor/artillery && npm install
cd suites/thumbnail-generator/artillery && npm install
```

Artillery CLI is run via `npx` (no global install required).

Applications: [`apps/`](../apps/).  
Platform-parallel guide: [PARALLEL-BENCHMARK.md](../docs/PARALLEL-BENCHMARK.md).
