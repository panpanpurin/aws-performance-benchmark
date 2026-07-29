# Host ports for concurrent benchmark suites

Each suite under `benchmarks/suites/<app>/` maps the shared stack to a **different host port range**. AniLove, CSV, and Thumbnail metrics stacks can run **at the same time**.

| Service | AniLove | CSV processor | Thumbnail |
|---------|---------|---------------|-----------|
| Prometheus | **9090** | **9190** | **9290** |
| Grafana | **3002** | **3102** | **3202** |
| Pushgateway ECS | **9092** | **9192** | **9292** |
| Pushgateway EC2 | **9093** | **9193** | **9293** |
| Pushgateway Lambda | **9094** | **9194** | **9294** |

| Item | Value |
|------|--------|
| Grafana login (all AWS suites) | `admin` / `123` |
| Artillery configs | `benchmarks/suites/<app>/artillery/test-*.yml` |

## Start all three stacks

```bash
make bench-anilove
make bench-csv
make bench-thumbnail
```

Or:

```bash
cd benchmarks/suites/anilove && docker compose up -d
cd benchmarks/suites/csv-processor && docker compose up -d
cd benchmarks/suites/thumbnail-generator && docker compose up -d
```

## Parallel Artillery

Within **one** suite, EC2 + ECS + Lambda should start together for aligned charts:

```bash
make artillery-anilove
make artillery-csv
make artillery-thumbnail
```

Those commands may also run concurrently across suites (non overlapping pushgateway ports).

## Grafana and Prometheus URLs

| Suite | Prometheus | Grafana |
|-------|------------|---------|
| AniLove | http://localhost:9090 | http://localhost:3002 |
| CSV | http://localhost:9190 | http://localhost:3102 |
| Thumbnail | http://localhost:9290 | http://localhost:3202 |

## Local stack interaction

[local/docker-compose.yml](../../local/docker-compose.yml) uses the **AniLove** range (9090, 3002, 9092 to 9094).

| Combination | OK? |
|-------------|-----|
| Local alone | Yes |
| Local + AniLove suite | No (port clash) |
| Local + CSV suite | Yes |
| Local + Thumbnail suite | Yes |
| All three AWS suites (no local) | Yes |

```bash
make bench-down-anilove
make bench-down-csv
make bench-down-thumbnail
make local-down
```
