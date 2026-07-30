# Artillery load test targets

Configs: `benchmarks/suites/<app>/artillery/test-*.yml`.

Each file ships with:

```yaml
config:
  target: "https://REPLACE_ME"
```

Set a real base URL **before** AWS load tests.

## Where to get URLs

After `terraform apply` (with DNS and/or compute enabled):

| Source | Contents |
|--------|----------|
| `terraform output public_hostnames` | EC2/ECS hostnames (when domain is set) |
| `terraform output lambda_function_urls` | Function URL per app |
| `terraform output alb_dns_name` | ALB DNS (Host header or HTTP base if no domain) |
| `terraform/generated/benchmark-targets.json` | Combined file when `write_benchmark_targets = true` |

| Suite file | Typical target |
|------------|----------------|
| `test-ec2.yml` | With domain: `https://anilove-ec2.<domain>`. Without domain: `http://<alb_dns_name>` and set header `Host: anilove-ec2.bench.local` |
| `test-ecs.yml` | Same pattern with `anilove-ecs.bench.local` (or your domain host) |
| `test-lambda.yml` | Function URL from output (includes `https://`) |

Without Route 53, Terraform still creates ALB host rules for `*.bench.local` so target groups stay attached. Use the ALB DNS from `terraform output alb_dns_name` plus the Host header.

Same pattern for CSV and Thumbnail suite files.

Local configs under `local/artillery/` already use localhost.

## Pushgateway ports (already set in YAML)

| Suite | ECS | EC2 | Lambda |
|-------|-----|-----|--------|
| AniLove | 9092 | 9093 | 9094 |
| CSV | 9192 | 9193 | 9194 |
| Thumbnail | 9292 | 9293 | 9294 |

| Related | Link |
|---------|------|
| Ports | [PORTS.md](./PORTS.md) |
| Prometheus | [PROMETHEUS-TARGETS.md](./PROMETHEUS-TARGETS.md) |
