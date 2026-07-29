# Benchmark suite: CSV Processor

App source: [apps/csv-processor](../../../apps/csv-processor).

```text
benchmarks/suites/csv-processor/
├── docker-compose.yml
├── prometheus.yml
├── grafana/dashboard.json
└── artillery/
    ├── fixtures/          # data.csv, pokes.csv
    ├── processor.js
    ├── package.json
    └── test-*.yml
```

Set Artillery `target` before AWS runs ([ARTILLERY-TARGETS.md](../../docs/ARTILLERY-TARGETS.md)).

```bash
cd benchmarks/suites/csv-processor
docker compose up -d
# or: make bench-csv

cd artillery
npm install   # first time (form-data)
run-parallel.bat
# or: make artillery-csv
```

| Service | URL |
|---------|-----|
| Prometheus | http://localhost:9190/targets |
| Grafana | http://localhost:3102/ (`admin` / `123`) |
| Pushgateway ECS / EC2 / Lambda | `:9192` / `:9193` / `:9194` |

| Related | Link |
|---------|------|
| Ports | [PORTS.md](../../docs/PORTS.md) |
| Parallel guide | [PARALLEL-BENCHMARK.md](../../../docs/PARALLEL-BENCHMARK.md) |
