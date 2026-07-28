# Prometheus targets

Each suite config: `benchmarks/suites/<app>/prometheus.yml`.

| Job type | Targets in repo | Notes |
|----------|-----------------|--------|
| `instrumented-metrics-*` | **Empty** `[]` | App `/metrics` hostnames or Lambda Function URLs |
| `node-exporter-*` | **Empty** `[]` | EC2/ECS host IPs `:9100` |
| `artillery-metrics-*` | Filled | Docker service names (`pushgateway-*:9091`) |

## Fill format

```yaml
static_configs:
  - targets: ['my-app-ec2.example.com']
    labels:
      service: app-instrumented-ec2
      environment: production
      instance: ec2
```

Lambda example:

```yaml
- targets: ['xxxx.lambda-url.ap-northeast-1.on.aws']
```

Node exporter:

```yaml
- targets: ['203.0.113.10:9100']
```

After editing, restart or reload Prometheus for that suite:

```bash
cd benchmarks/suites/anilove
docker compose up -d
# or: curl -X POST http://localhost:9090/-/reload
```

Automation can replace empty `targets: []` lists without changing job names or labels.
