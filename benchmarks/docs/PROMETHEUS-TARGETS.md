# Prometheus targets

Suite config: `benchmarks/suites/<app>/prometheus.yml`.

`make sync-targets` fills all three `instrumented-metrics-*` jobs. Edit by hand
only when working without terraform outputs.

| Job type | In repo | Notes |
|----------|---------|--------|
| `instrumented-metrics-ec2/-ecs` | metrics-proxy port | With a domain: the ALB hostname plus `scheme: https`. Without one: `host.docker.internal:<proxy port>` |
| `instrumented-metrics-lambda` | Empty `[]` | Host part of the Function URL, `scheme: https` |
| `node-exporter-*` | Empty `[]` | Optional EC2/ECS `:9100` |
| `artillery-metrics-*` | Filled | Compose service names (`pushgateway-*:9091`) |

## Where to get hostnames

| Source | Use |
|--------|-----|
| `terraform output public_hostnames` | EC2/ECS ALB hostnames |
| `terraform output lambda_function_urls` | Host part of Function URL for scrape |
| `generated/benchmark-targets.json` | Snapshot after apply |

## Fill format

EC2/ECS with a domain (hostname resolves, certificate covers it):

```yaml
scheme: https
static_configs:
  - targets: ['anilove-ec2.example.com']
    labels:
      service: app-instrumented-ec2
      environment: production
      instance: ec2
```

Without a domain, drop `scheme` and point at the metrics proxy on the host
(`host.docker.internal:18080`); see [PORTS.md](./PORTS.md) for the port map.

Lambda (host only, no `https://`):

```yaml
- targets: ['xxxx.lambda-url.ap-northeast-1.on.aws']
```

Node exporter:

```yaml
- targets: ['203.0.113.10:9100']
```

Reload Prometheus after edits:

```bash
cd benchmarks/suites/anilove
docker compose up -d
# or: curl -X POST http://localhost:9090/-/reload
```

Keep job names and label keys; only replace empty `targets` lists.
