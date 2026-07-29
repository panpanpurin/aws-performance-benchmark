# Prometheus targets

Suite config: `benchmarks/suites/<app>/prometheus.yml`.

| Job type | In repo | Notes |
|----------|---------|--------|
| `instrumented-metrics-*` | Empty `[]` | App `/metrics` hosts or Lambda Function URL host |
| `node-exporter-*` | Empty `[]` | Optional EC2/ECS `:9100` |
| `artillery-metrics-*` | Filled | Compose service names (`pushgateway-*:9091`) |

## Where to get hostnames

| Source | Use |
|--------|-----|
| `terraform output public_hostnames` | EC2/ECS ALB hostnames |
| `terraform output lambda_function_urls` | Host part of Function URL for scrape |
| `generated/benchmark-targets.json` | Snapshot after apply |

## Fill format

```yaml
static_configs:
  - targets: ['anilove-ec2.example.com']
    labels:
      service: app-instrumented-ec2
      environment: production
      instance: ec2
```

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
