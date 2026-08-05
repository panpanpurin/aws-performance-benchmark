# Benchmark scripts

| Script | Purpose |
|--------|---------|
| `run-parallel.sh` | Parallel Artillery (EC2 + ECS + Lambda) for one suite |

```bash
./run-parallel.sh anilove
./run-parallel.sh anilove pilot   # short probe, see scripts/make-pilot-configs.sh
make artillery-anilove
```

Each platform writes a `.log` and a `.json` report to the suite's
`artillery/logs/`. When the run ends the script publishes the client-side and
Lambda CloudWatch series from those reports, which is what fills the dashboard's
lower two rows, the `publish-metrics` plugin alone only pushes its last
reporting interval and never emits the 4xx/5xx counts. Both pushes need the
suite's metrics stack up (`make bench-<suite>`); the CloudWatch one also needs
AWS credentials. Neither failing stops the run.

Repo-wide automation: [scripts/README.md](../../scripts/README.md).
