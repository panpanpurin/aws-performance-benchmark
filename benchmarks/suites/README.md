# Benchmark suites

One folder per workload. Same layout for all three.

```text
suites/
├── anilove/
├── csv-processor/
└── thumbnail-generator/
```

Each suite:

| Path | Role |
|------|------|
| `docker-compose.yml` | Includes `../../stack`, host ports, mounts `prometheus.yml` |
| `prometheus.yml` | Scrape targets (app/node-exporter empty until filled) |
| `grafana/dashboard.json` | Suite dashboard |
| `artillery/` | Load tests (`test-ec2|ecs|lambda.yml`) + runners |
| `artillery/fixtures/` | Sample inputs (CSV images), when needed |

## Ports

| Suite | Prometheus | Grafana | Pushgateways |
|-------|------------|---------|--------------|
| AniLove | 9090 | 3002 | 9092-9094 |
| CSV | 9190 | 3102 | 9192-9194 |
| Thumbnail | 9290 | 3202 | 9292-9294 |

Full table: [../docs/PORTS.md](../docs/PORTS.md).

## Run

```bash
# metrics stack
make bench-anilove   # or bench-csv / bench-thumbnail

# parallel Artillery (shared script under benchmarks/scripts/)
make artillery-anilove
# or:
cd anilove/artillery && ./run-parallel.sh
```

## Artillery dependencies

- **AniLove:** no suite-local `package.json` (JSON-only scenarios).
- **CSV / Thumbnail:** `form-data` is required by the request processors.

```bash
# only when needed (first run, or after clean checkout without node_modules)
cd csv-processor/artillery && npm install
cd thumbnail-generator/artillery && npm install
```

Artillery itself is started via `npx artillery@2.0.23` (no global install required).

Set each `test-*.yml` `target` before AWS runs (`https://REPLACE_ME` in repo). See [../docs/ARTILLERY-TARGETS.md](../docs/ARTILLERY-TARGETS.md).
