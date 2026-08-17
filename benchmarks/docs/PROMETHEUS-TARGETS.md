# Prometheus targets

Suite config: `benchmarks/suites/<app>/prometheus.yml`.

`make sync-targets` fills all three `instrumented-metrics-*` jobs. Edit by hand
only when working without terraform outputs.

| Job type | In repo | Notes |
|----------|---------|--------|
| `instrumented-metrics-ec2/-ecs` | `["REPLACE_ME"]` | With a domain: the ALB hostname plus `scheme: https`. Without one: `host.docker.internal:<proxy port>` |
| `instrumented-metrics-lambda` | `["REPLACE_ME"]` | Host part of the Function URL, `scheme: https` |
| `artillery-metrics-*` | Filled | Compose service names (`pushgateway-*:9091`) |

The placeholder is a literal `REPLACE_ME`, not an empty list, so a suite that was
never synced fails its scrape loudly instead of looking idle.

Note that `make validate-bench` will **not** catch it here. It rejects a
`REPLACE_ME` left in an Artillery `target`, and rejects Prometheus targets that
are empty, but a Prometheus job still holding the placeholder passes. Run `make
sync-targets`, then confirm on Prometheus → Status → Targets before a run that
costs money.

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

Reload Prometheus after edits:

```bash
cd benchmarks/suites/anilove
docker compose up -d
# or: curl -X POST http://localhost:9090/-/reload
```

Keep job names and label keys; only replace empty `targets` lists.
