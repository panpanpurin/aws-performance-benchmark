# Benchmark suites

One folder per workload. Same layout for all three.

```text
suites/
├── anilove/
├── csv-processor/
└── thumbnail-generator/
```

| Path | Role |
|------|------|
| `docker-compose.yml` | Includes `../../stack`, host ports, mounts `prometheus.yml` |
| `prometheus.yml` | Scrape targets (app and node exporter empty until filled) |
| `grafana/dashboard.json` | Suite dashboard |
| `artillery/` | Load tests (`test-ec2|ecs|lambda.yml`) + runners |
| `artillery/fixtures/` | Sample inputs when needed |

## Ports

| Suite | Prometheus | Grafana | Pushgateways |
|-------|------------|---------|--------------|
| AniLove | 9090 | 3002 | 9092 to 9094 |
| CSV | 9190 | 3102 | 9192 to 9194 |
| Thumbnail | 9290 | 3202 | 9292 to 9294 |

Full table: [PORTS.md](../docs/PORTS.md).

## Run

```bash
make bench-anilove   # or bench-csv / bench-thumbnail
make artillery-anilove
# or: cd anilove/artillery && ./run-parallel.sh
```

## Artillery dependencies

| Suite | Notes |
|-------|--------|
| AniLove | No suite local `package.json` (JSON only scenarios) |
| CSV / Thumbnail | `form-data` required by request processors |

```bash
cd csv-processor/artillery && npm install
cd thumbnail-generator/artillery && npm install
```

Artillery CLI: `npx artillery@2.0.23` (no global install).

Set each `test-*.yml` `target` before AWS runs (`https://REPLACE_ME` in repo). See [ARTILLERY-TARGETS.md](../docs/ARTILLERY-TARGETS.md).
