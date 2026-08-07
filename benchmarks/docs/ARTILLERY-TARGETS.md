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

| Suite file | With a domain (current) | Without a domain |
|------------|-------------------------|------------------|
| `test-ec2.yml` | `https://anilove-ec2.<domain>` | `http://<alb_dns_name>` + header `Host: anilove-ec2.bench.local` |
| `test-ecs.yml` | `https://anilove-ecs.<domain>` | same, `Host: anilove-ecs.bench.local` |
| `test-lambda.yml` | `https://anilove-lambda.<domain>` | same, `Host: anilove-lambda.bench.local`. With `lambda_behind_alb = false`, the Function URL instead (includes `https://`) |

All three platforms go through the same ALB and the same request path; only the
hostname they are routed on differs. That is what keeps the comparison fair.

With a domain the hostnames resolve and the wildcard certificate covers them, so
the target carries the hostname and no `Host` header is needed, TLS is
negotiated from the URL, so pointing at the ALB DNS name with a `Host` header
would fail certificate validation.

Without Route 53, Terraform still creates ALB host rules for `*.bench.local` so target groups stay attached. Those names resolve nowhere, so use the ALB DNS from `terraform output alb_dns_name` plus the `Host` header.

Same pattern for CSV and Thumbnail, with labels `csv` and `thumb` instead of `anilove`.

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
