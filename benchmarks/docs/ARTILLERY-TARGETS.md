# Artillery load-test targets

AWS Artillery configs live under `benchmarks/suites/<app>/artillery/test-*.yml`.

Each file has:

```yaml
config:
  target: "https://REPLACE_ME"
```

Replace `https://REPLACE_ME` with the real base URL before running load tests.

| Suite | File | Typical target |
|-------|------|----------------|
| AniLove | `test-ec2.yml` | EC2 HTTPS base URL |
| AniLove | `test-ecs.yml` | ECS/ALB HTTPS base URL |
| AniLove | `test-lambda.yml` | Lambda Function URL |
| CSV | same pattern | CSV service base URLs |
| Thumbnail | same pattern | Thumbnail service base URLs |

Local Artillery configs under `local/artillery/` already use localhost and do not need this step.

Pushgateway ports (already set per suite):

| Suite | ECS | EC2 | Lambda |
|-------|-----|-----|--------|
| AniLove | 9092 | 9093 | 9094 |
| CSV | 9192 | 9193 | 9194 |
| Thumbnail | 9292 | 9293 | 9294 |

See also [PORTS.md](./PORTS.md) and [PROMETHEUS-TARGETS.md](./PROMETHEUS-TARGETS.md).
