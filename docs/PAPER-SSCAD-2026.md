# Companion to the SSCAD-WIC 2026 paper

What the paper measures, how each reported number is obtained from this
repository, and what the results do not support.

This repository compares **EC2**, **ECS on EC2**, and **AWS Lambda** across
three workloads with different bottlenecks. Every platform runs the same source
from the same image tree, behind the same VPC, ALB, and RDS instance, so the
compute model is the only intended difference.

| Workload | Bottleneck | Stack |
|----------|-----------|-------|
| `anilove` | I/O-bound (PostgreSQL) | Express 5, Sequelize |
| `csv-processor` | CPU and memory (pandas) | FastAPI, pandas |
| `thumbnail-generator` | CPU-bound media | Express 5, Sharp |

## Experimental setup

| Parameter | Value |
|-----------|-------|
| Region | ap-northeast-1 (Tokyo) |
| EC2 | `t2.micro`, one instance per workload |
| ECS on EC2 | `t3.small` container instances; task 1024 CPU units / 1024 MB |
| Lambda | 1024 MB memory, 1024 MB ephemeral, 30 s timeout, container image |
| Database | one `db.t4g.micro` PostgreSQL 17.6, Single-AZ, shared by all platforms |
| Load generator | Artillery 2.0.23, five phases, ~32 min per run |
| Requests per run | 43,800 (anilove), 38,880 (csv), 13,740 (thumbnail) |

CPU is pinned to approximate one vCPU on every platform:
`OMP_NUM_THREADS=OPENBLAS_NUM_THREADS=1` for csv-processor and
`sharp.concurrency(1)` for thumbnail-generator. Removing either invalidates the
comparison; `make validate-fairness` checks that they are present.

The three platforms are loaded **concurrently**, in one shared time window, so
that external conditions are common to all of them. This trades isolation for
comparability.

## Metrics reported in the paper

All applications expose the same metric names on all platforms, so one
dashboard splits series by the `instance` label (`ec2` / `ecs` / `lambda`).
Reference implementation: `apps/anilove/src/metrics.js`.

| Metric | Meaning |
|--------|---------|
| `app_total_execution_time_seconds` | Full request time measured inside the application |
| `app_internal_processing_time_seconds` | Same, minus time spent waiting on PostgreSQL |
| `app_cold_start_duration_seconds` | Runtime init to first invocation; Lambda only, once per container |
| `app_cpu_usage_percent` | Process CPU over the sampling interval |
| `app_ram_peak_mb` | Peak resident memory since process start |
| `artillery_rates{metric="http_request_rate"}` | Throughput, client-side |
| `artillery_summaries` 2xx ratio | Error rate, client-side |

The difference between the first two is time waiting on the database. AniLove
tracks it with `AsyncLocalStorage` fed by Sequelize's `benchmark` logger, which
is what separates platform overhead from application work.

More metrics are instrumented than the paper reports
(`app_cpu_peak_percent`, `app_ram_usage_mb`, client-side latency, host-level
CPU and memory). They remain available in the dashboards under
`benchmarks/suites/*/grafana/`.

## Queries behind each number

Set the query range to a **single load phase**. Averaging across phases mixes
warm-up into the stress peak.

```promql
# Latency P95, milliseconds (P99: replace 0.95)
histogram_quantile(
  0.95,
  sum by (le, instance) (rate(app_total_execution_time_seconds_bucket[5m]))
) * 1000

# Latency mean, milliseconds
1000 * sum by (instance) (rate(app_total_execution_time_seconds_sum[5m]))
     / clamp_min(sum by (instance) (rate(app_total_execution_time_seconds_count[5m])), 1e-9)

# Database wait, milliseconds (means only - see below)
1000 * (
  sum by (instance) (rate(app_total_execution_time_seconds_sum[5m]))
  - sum by (instance) (rate(app_internal_processing_time_seconds_sum[5m]))
) / clamp_min(sum by (instance) (rate(app_total_execution_time_seconds_count[5m])), 1e-9)

# Cold start mean, and the sample count it is based on
1000 * sum(increase(app_cold_start_duration_seconds_sum[6h]))
     / clamp_min(sum(increase(app_cold_start_duration_seconds_count[6h])), 1)
sum(increase(app_cold_start_duration_seconds_count[6h]))

# Resources and load
avg by (instance) (avg_over_time(app_cpu_usage_percent[5m]))
max by (instance) (max_over_time(app_ram_peak_mb[5m]))
avg by (service) (artillery_rates{metric="http_request_rate"})

# Error rate (%)
100 * (1 -
  sum by (service) (artillery_summaries{metric="http_response_time_2xx_count"})
  / sum by (service) (artillery_summaries{metric="http_response_time_count"})
)
```

## Reading the results correctly

**Percentiles do not subtract.** `P95(total) - P95(internal)` is not the
95th-percentile database wait, because the request at the 95th percentile of
total time is generally not the one at the 95th percentile of internal time.
Only means are additive, so the database-wait figure is mean-based.

**Cold start has a small sample size.** It is recorded once per container and
only when Lambda environment variables are present, so *n* is the number of
cold containers, not the number of requests. The paper reports *n* alongside
the percentiles.

**Every latency value belongs to one load phase.** Phase and workload are named
in each figure caption.

## Reproducing a run

Requires AWS credentials, Docker, Terraform >= 1.5, and Node.

```bash
make check                # tools and credentials
cp terraform/backend.tf.example terraform/backend.tf   # fill in, see terraform/README.md
make validate-tf          # fmt, validate, backend, tfvars, ECR images
make apply
make push-images
make sync-targets         # fills the REPLACE_ME targets from terraform outputs
make ecs-up
make validate-aws         # every target healthy, not just one
make validate-fairness    # metric names, CPU pins, deployed specs
make bench-anilove        # Prometheus + Grafana; also bench-csv, bench-thumbnail
make metrics-proxy        # required for anilove, leave running
make validate-bench       # config check before a 30+ minute run
make artillery-anilove    # EC2 + ECS + Lambda in parallel
make ecs-down             # or make destroy
```

A full session costs roughly US$ 3 and takes about 8 hours including setup and
teardown. See [COSTS.md](./COSTS.md).

The repository ships with Artillery targets set to `https://REPLACE_ME` and
with empty Prometheus scrape targets for the csv and thumbnail suites.
`make sync-targets` fills the former; the latter are filled manually per
[PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md).

## Limitations

- **The database is shared.** One `db.t4g.micro` serves AniLove on all three
  platforms; `DB_SCHEMA` isolates data, not load. Concurrent runs contend for
  the same CPU and IOPS, and that contention is part of the measured database
  wait.
- **Node dependency versions are not locked.** No `package-lock.json` is
  committed and `package.json` uses `^` ranges, so a rebuild at a later date
  can resolve a different tree. This matters most for `sharp`, which is the
  thumbnail workload's cost. Python dependencies are pinned exactly in
  `requirements.txt`. Base images are floating tags. Record the resolved
  versions at run time with
  `docker run --rm <image> npm ls --omit=dev --depth=0`.
- **Burstable instances.** `t2.micro` and `t3.small` run on CPU credits.
  Credit depletion during the stress phase is a real effect, but the results
  do not describe dedicated-capacity instances.
- **One region, and however many repetitions were performed.** All numbers come
  from ap-northeast-1. A single run per configuration supports no claim about
  variance.
- **Lambda is not behind the ALB.** It is reached through Function URLs, so its
  network path differs from EC2 and ECS. Server-side metrics exclude this
  difference; client-side latency does not.

## Where to look

| Path | Contents |
|------|----------|
| [WORKLOADS.md](./WORKLOADS.md) | What each application computes |
| [INFRASTRUCTURE.md](./INFRASTRUCTURE.md) | AWS layout and its explicit non-goals |
| [COSTS.md](./COSTS.md) | Cost of one measurement session |
| [PARALLEL-BENCHMARK.md](./PARALLEL-BENCHMARK.md) | Why the platforms run concurrently |
| `apps/*/src/metrics.js`, `apps/csv-processor/app/metrics.py` | Instrumentation |
| `benchmarks/suites/*/artillery/` | Load phase definitions |
| `benchmarks/suites/*/grafana/dashboard.json` | Dashboards |
| `terraform/` | Infrastructure, one module per concern |
