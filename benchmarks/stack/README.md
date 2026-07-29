# Shared metrics stack

Prometheus, Grafana, and three pushgateways used by every suite under `benchmarks/suites/<app>/`.

Defined once and included by each suite compose file. Each suite:

1. Maps **different host ports** (suites can run concurrently)
2. Mounts its own `prometheus.yml`
3. Keeps Artillery configs and `grafana/dashboard.json`

```bash
# Start via a suite (not this folder alone)
cd benchmarks/suites/anilove
docker compose up -d
```

Port map: [PORTS.md](../docs/PORTS.md).

| Service | AniLove (default) | CSV | Thumbnail |
|---------|-------------------|-----|-----------|
| Prometheus | 9090 | 9190 | 9290 |
| Grafana | 3002 | 3102 | 3202 |
| Pushgateway ECS | 9092 | 9192 | 9292 |
| Pushgateway EC2 | 9093 | 9193 | 9293 |
| Pushgateway Lambda | 9094 | 9194 | 9294 |

Grafana login (AWS suites): `admin` / `123`.
