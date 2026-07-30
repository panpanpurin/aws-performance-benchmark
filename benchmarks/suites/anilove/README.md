# Benchmark suite: AniLove

App source: [apps/anilove](../../../apps/anilove).

```text
benchmarks/suites/anilove/
├── docker-compose.yml
├── prometheus.yml
├── grafana/dashboard.json
└── artillery/
    ├── test-ec2.yml | test-ecs.yml | test-lambda.yml
    └── run-parallel.sh (or .bat -> bash)
```

## Metrics stack

```bash
cd benchmarks/suites/anilove
docker compose up -d
# or: make bench-anilove
```

| Service | URL |
|---------|-----|
| Prometheus | http://localhost:9090/targets |
| Grafana | http://localhost:3002/ (`admin` / `123`) |
| Pushgateway ECS / EC2 / Lambda | `:9092` / `:9093` / `:9094` |

Other suites use different host ports. See [PORTS.md](../../docs/PORTS.md).

Import `grafana/dashboard.json` if needed.

## Artillery

Set `target` in each `test-*.yml` first ([ARTILLERY-TARGETS.md](../../docs/ARTILLERY-TARGETS.md)).

```bash
cd artillery
./run-parallel.sh
# or from repo root: make artillery-anilove
```

Guide: [PARALLEL-BENCHMARK.md](../../../docs/PARALLEL-BENCHMARK.md).
