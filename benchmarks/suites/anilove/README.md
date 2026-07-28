# Benchmark suite: AniLove

```text
benchmarks/suites/anilove/
├── docker-compose.yml      # includes ../../stack + host ports
├── prometheus.yml          # scrape targets (empty until filled)
├── grafana/
│   └── dashboard.json
└── artillery/
    ├── test-ec2.yml | test-ecs.yml | test-lambda.yml
    └── run-parallel.bat | .ps1 | .sh
```

App source: [`apps/anilove`](../../../apps/anilove).

## Metrics stack

```bash
cd benchmarks/suites/anilove
docker compose up -d
# or: make bench-anilove
```

| Service | URL |
|---------|-----|
| Prometheus | http://localhost:9090/targets |
| Grafana | http://localhost:3002/ (admin / `123`) |
| Pushgateway ECS / EC2 / Lambda | `:9092` / `:9093` / `:9094` |

Other suites use different host ports. See [../../docs/PORTS.md](../../docs/PORTS.md).

Import `grafana/dashboard.json` if needed.

## Artillery

```bash
cd artillery
npx artillery@2.0.23 run test-ec2.yml
run-parallel.bat
# or: make artillery-anilove
```

Guide: [PARALLEL-BENCHMARK.md](../../../docs/PARALLEL-BENCHMARK.md).
