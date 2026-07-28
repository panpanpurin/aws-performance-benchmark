# Benchmark suite: Thumbnail Generator

App source: [`apps/thumbnail-generator`](../../../apps/thumbnail-generator).

```text
benchmarks/suites/thumbnail-generator/
├── docker-compose.yml
├── prometheus.yml
├── grafana/dashboard.json
└── artillery/
    ├── fixtures/          # sample.jpg
    ├── upload-image.js
    ├── package.json       # form-data only; npm install if needed
    └── test-*.yml
```

```bash
cd benchmarks/suites/thumbnail-generator
docker compose up -d
# or: make bench-thumbnail

cd artillery
# first time only (form-data for multipart uploads):
npm install
run-parallel.bat
# or: make artillery-thumbnail
```

| Service | URL |
|---------|-----|
| Prometheus | http://localhost:9290/targets |
| Grafana | http://localhost:3202/ (admin / `123`) |
| Pushgateway ECS / EC2 / Lambda | `:9292` / `:9293` / `:9294` |

Ports: [../../docs/PORTS.md](../../docs/PORTS.md).  
Guide: [PARALLEL-BENCHMARK.md](../../../docs/PARALLEL-BENCHMARK.md).
