# Benchmark suite: CSV Processor

App source: [`apps/csv-processor`](../../../apps/csv-processor).

```text
benchmarks/suites/csv-processor/
├── docker-compose.yml
├── prometheus.yml
├── grafana/dashboard.json
└── artillery/
    ├── fixtures/          # data.csv, pokes.csv
    ├── processor.js
    ├── package.json       # form-data only; npm install if needed
    └── test-*.yml
```

```bash
cd benchmarks/suites/csv-processor
docker compose up -d
# or: make bench-csv

cd artillery
# first time only (form-data for multipart uploads):
npm install
run-parallel.bat
# or: make artillery-csv
```

| Service | URL |
|---------|-----|
| Prometheus | http://localhost:9190/targets |
| Grafana | http://localhost:3102/ (admin / `123`) |
| Pushgateway ECS / EC2 / Lambda | `:9192` / `:9193` / `:9194` |

Ports: [../../docs/PORTS.md](../../docs/PORTS.md).  
Guide: [PARALLEL-BENCHMARK.md](../../../docs/PARALLEL-BENCHMARK.md).
