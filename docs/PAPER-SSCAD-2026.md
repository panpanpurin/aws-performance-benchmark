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
| EC2 | `c6i.large` host, one per workload; container capped at 1 vCPU / 1024 MB |
| ECS on EC2 | `c6i.large` hosts; task 1024 CPU units (1 vCPU) / 1024 MB |
| Lambda | 1769 MB (one full vCPU), 1024 MB ephemeral, 30 s timeout, container image, **reserved concurrency 1** |
| Database | one `db.t4g.micro` PostgreSQL 17.6, Single-AZ, shared by all platforms |
| Load generator | Artillery 2.0.23, five phases, ~32 min per run |
| Requests per run | 43,800 (anilove), 38,880 (csv), 13,740 (thumbnail) |

**Every platform gets one vCPU and 1 GB**, enforced three different ways: the
ECS task definition caps CPU units and memory, the EC2 `docker run` is given
`--cpus` and `--memory` matching that task, and Lambda is set to 1769 MB, the
point at which it allocates one full vCPU.

Two consequences worth stating in the paper:

- **Lambda couples CPU to memory.** Matching CPU at 1769 MB necessarily gives
  Lambda ~1.7x the memory of the other platforms. You can match CPU or memory,
  not both. CPU was chosen because two of the three workloads are CPU-bound;
  `app_ram_peak_mb` shows that memory was never the binding constraint.
- **The hosts are non-burstable.** `c6i.large` replaces the `t2.micro` /
  `t3.small` pair used in earlier revisions, because burstable instances
  throttle once CPU credits are exhausted, t2 and t3 default to opposite credit
  modes, and credit balance carries across runs so repetitions are not
  independent. Half of each `c6i.large` is intentionally idle, since AWS offers
  no 1-vCPU non-burstable instance type. Full reasoning:
  [INFRASTRUCTURE.md](./INFRASTRUCTURE.md#instance-type-choice-why-not-burstable).
  If the paper reports data collected before this change, it must say so — the
  two configurations are not comparable.

### Equal capacity, not just equal cores

Matching vCPU is not enough on its own. EC2 serves with one container and ECS
with one task, while Lambda scales horizontally by default: at 50 req/s with
half-second responses it would run ~25 sandboxes and hold ~25x the aggregate
CPU of the other two. That difference is elasticity, not the compute model.

`lambda_reserved_concurrency = 1` caps each function at one concurrent
execution, so every platform serves with exactly one 1-vCPU worker and the
measurement isolates per-request cost. Set it to `-1` to remove the cap and
measure elasticity instead; `make validate-fairness` reports which mode is
active and fails if the deployed cap does not match `terraform.tfvars`.

Two consequences must be stated in the paper:

- **Lambda rejects, it does not queue.** Synchronous invocations beyond the
  reserved concurrency return HTTP 429 immediately, whereas EC2 and ECS queue
  and degrade. Above saturation, Lambda's latency therefore looks *better*
  because only served requests are timed, while its error rate rises sharply.
  Report latency and error rate together, or the comparison misleads.
- **Autoscaling is excluded by design.** This is the defensible answer to a
  reviewer who objects that Lambda was handicapped: the experiment measures
  per-request cost of the compute model, and elasticity is a separate dimension
  the design deliberately holds constant.

### Load phases must stay near or below saturation

One worker at 1 vCPU has a hard throughput ceiling of roughly
`1 / mean_service_time`. Using the duration estimates in
[COSTS.md](./COSTS.md), the committed phase schedule oversaturates every suite:

| Suite | Est. service time | Ceiling at 1 worker | Committed peak |
|-------|------------------|---------------------|----------------|
| anilove | ~45 ms | ~22 req/s | 50 req/s |
| csv-processor | ~175 ms | ~5.7 req/s | 28 req/s |
| thumbnail-generator | ~290 ms | ~3.4 req/s | 12 req/s |

Run entirely above the ceiling and the result is queueing on EC2/ECS versus
rejection on Lambda, not per-request cost. Before the measurement runs, do one
short pilot to obtain real service times from
`app_total_execution_time_seconds`, then set the steady phase to roughly 60-70%
of the measured ceiling and let only the stress phase cross it. That gives one
regime for the latency comparison and one for the saturation comparison.

Thread usage is additionally pinned inside the applications:
`OMP_NUM_THREADS=OPENBLAS_NUM_THREADS=1` for csv-processor and
`sharp.concurrency(1)` for thumbnail-generator. `make validate-fairness`
checks that these are present, and `make validate-tf` checks the vCPU budgets
match across platforms.

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

A full session costs roughly US$ 7 and takes about 8 hours including setup and
teardown. See [COSTS.md](./COSTS.md).

### How many repetitions

**Five per configuration; three is the defensible floor.** At ~US$ 7 per
session that is about US$ 37 for the whole study.

Run each repetition on **freshly provisioned instances** (`make destroy` then
`make apply`), not back to back on the same stack. This also gives every
repetition fresh Lambda containers, so each one contributes new cold-start
samples — the metric that benefits most from repetition, since its *n* is the
number of cold containers rather than the number of requests.

Aggregate as **median and min-max across runs, not mean and standard
deviation**: latency distributions are right-skewed and normality cannot be
demonstrated at n=5. Compute the per-run statistic first, then aggregate. The
median across five runs of each run's P95 is a valid quantity; the mean of five
P95 values is not, and captions should say which was used.

Present it as: bars at the median with whiskers at min-max for the latency
figures, one representative run for the phase time series (averaging across
runs smears the phase boundaries), and median [min, max] per cell in the
results table. If a statistical claim is needed, Kruskal-Wallis across the
three platforms using per-run medians as observations is appropriate at this
sample size.

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
- **Half of each host is idle.** `c6i.large` has 2 vCPUs and the container is
  capped at 1, because no 1-vCPU non-burstable type exists. Results therefore
  describe an application confined to one vCPU on an otherwise unloaded host,
  not a fully packed instance.
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
