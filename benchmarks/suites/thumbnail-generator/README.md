# Benchmark suite: Thumbnail Generator

App source: [apps/thumbnail-generator](../../../apps/thumbnail-generator).

```text
benchmarks/suites/thumbnail-generator/
├── docker-compose.yml
├── prometheus.yml
├── grafana/dashboard.json
└── artillery/
    ├── fixtures/          # sample.jpg
    ├── upload-image.js
    ├── package.json
    └── test-*.yml
```

Set Artillery `target` before AWS runs ([ARTILLERY-TARGETS.md](../../docs/ARTILLERY-TARGETS.md)).

```bash
cd benchmarks/suites/thumbnail-generator
docker compose up -d
# or: make bench-thumbnail

cd artillery
npm install   # first time (form-data)
run-parallel.bat
# or: make artillery-thumbnail
```

| Service | URL |
|---------|-----|
| Prometheus | http://localhost:9290/targets |
| Grafana | http://localhost:3202/ (`admin` / `123`) |
| Pushgateway ECS / EC2 / Lambda | `:9292` / `:9293` / `:9294` |

| Related | Link |
|---------|------|
| Ports | [PORTS.md](../../docs/PORTS.md) |
| Parallel guide | [PARALLEL-BENCHMARK.md](../../../docs/PARALLEL-BENCHMARK.md) |
