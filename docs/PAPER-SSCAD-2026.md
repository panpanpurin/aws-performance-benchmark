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
| `csv-processor` | CPU (pandas), see the note below | FastAPI, pandas |
| `thumbnail-generator` | CPU-bound media | Express 5, Sharp |

## Experimental setup

| Parameter | Value |
|-----------|-------|
| Region | ap-northeast-1 (Tokyo) |
| EC2 | `c6i.large` host, one per workload; container capped at 1 vCPU / 1024 MB |
| ECS on EC2 | `c6i.large` hosts; task 1024 CPU units (1 vCPU) / 1024 MB |
| Lambda | 1769 MB (one full vCPU), 1024 MB ephemeral, 30 s timeout, container image, **reserved concurrency 1** |
| Database | one `db.m6g.large` PostgreSQL 17.6, Single-AZ, shared by all platforms |
| Load generator | Artillery 2.0.23, in-region; five phases, ~27 min per csv run, ~33 min per thumbnail run |
| Arrivals per run | 8,640 (anilove, provisional), **20,280 (csv, measured phases)**, **5,580 (thumbnail, derived phases)** |
| HTTP requests per run | **43,200** (anilove, 5 per arrival), 20,280 (csv), 5,580 (thumbnail) |

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

- **Lambda rejects, it does not queue — and it starts rejecting far below the
  ceiling.** Invocations beyond the reserved concurrency are throttled, whereas
  EC2 and ECS queue and degrade. Above saturation Lambda's latency therefore
  looks *better*, because only served requests are timed, while its error rate
  rises sharply. Report latency and error rate together, or the comparison
  misleads.

  Measured, 2026-08-03, csv-processor at **2 req/s** — about 7% of Lambda's
  28 req/s ceiling: 780 requests produced 621 × 200 and **159 × HTTP 502**,
  and CloudWatch confirmed **156 throttles and 0 errors**. EC2 and ECS served
  the identical arrival pattern with zero failures.

  The cause is arrival burstiness, not utilisation. Artillery's `arrivalRate: N`
  starts N virtual users at essentially the same instant each second rather than
  spacing them evenly, so at concurrency 1 the second arrival in a burst is
  rejected outright. A socket backlog and an event loop absorb that; a Lambda
  sandbox at reserved concurrency 1 has nowhere to put it.

  Two consequences for the phase schedule. First, `ceiling = 1/service_time`
  assumes smooth arrivals, so with `arrivalRate` it describes EC2 and ECS well
  and Lambda badly. Using `arrivalCount` removes the burst and the ceiling
  becomes predictive again, provided it is computed from CloudWatch `Duration`
  rather than the in-app timer. Second, any run at matched arrival rates will
  attribute to Lambda a failure rate that is a property of the queueing model,
  not of the compute model. State which is being measured.

- **A throttled Lambda behind the ALB returns 502, not 429.** The ALB converts
  the throttle rather than passing the status through. Filtering results on 429
  reports zero throttles no matter how many occurred; count 502 responses, or
  read `Throttles` from the `AWS/Lambda` CloudWatch namespace, which is
  authoritative and separates throttles from genuine function errors.
- **Autoscaling is excluded by design.** This is the defensible answer to a
  reviewer who objects that Lambda was handicapped: the experiment measures
  per-request cost of the compute model, and elasticity is a separate dimension
  the design deliberately holds constant.

### Two experiments, not one

Elasticity is held constant in Experiment A and then released in Experiment B,
against the same arrival schedule. Both run against all three applications. They
answer different questions, use different Lambda configurations, and —
importantly — **read Lambda's numbers from different places**.

| | **A — per-request cost** | **B — effect of the cap** |
|---|---|---|
| Question | What does one request cost on each compute model? | What does the concurrency limit itself cost? |
| `lambda_reserved_concurrency` | `1` | `-1` |
| Workers | 1 vCPU each, all three platforms | EC2/ECS 1 vCPU; Lambda scales to the account limit |
| Load | Below every platform's ceiling | **The same schedule as A** |
| Lambda metric source | Prometheus `app_*` | **CloudWatch** (see below) |
| Reported | Latency mean/P95/P99, CPU per request, RAM | Concurrency reached, cold starts, error rate |

B runs the *same* arrival schedule as A with the cap removed, so the difference
between them is attributable to the concurrency limit alone.

Switching between them is one line in `terraform.tfvars` plus `make apply`, so
both are cheap to run in a session. `make validate-fairness` reports which mode
is deployed and warns when Lambda is uncapped.

**Why B cannot be compared head-to-head with A.** Measured on csv-processor at
60 req/s: uncapped Lambda served 5400 of 5400 requests with **zero throttles**,
reaching **59 concurrent sandboxes** — roughly 59 vCPUs. EC2 and ECS, holding
one vCPU each, returned 5400 × 200 but logged ~5000 `ETIMEDOUT` apiece from
queueing. Lambda did not win on compute; it was given 59 times the capacity.
Reporting those latencies side by side would be meaningless, which is precisely
what `reserved_concurrency = 1` exists to prevent in Experiment A.

**Lambda's `app_*` metrics are valid only while it runs a single sandbox.** Each
sandbox holds its own in-memory Prometheus registry and a scrape returns
whichever one answered it, so with more than one the figures are a sample rather
than an aggregate. Measured with just two sandboxes, the served rate read
36.83 req/s against a true 2.00, and latency read 23.32 ms against CloudWatch's
36.3 ms — an error invisible on the chart, because 23 ms looks perfectly
reasonable. With 59 sandboxes several series read 0 while one read 817.

The condition is the **sandbox count, not the cap**. Uncapping does not by
itself create a second sandbox: measured uncapped at 2 req/s with smoothed
arrivals, peak concurrency stayed at 1 and the `app_*` figures matched the
capped run exactly (22.82 vs 22.73 ms mean, 2.00 req/s served in both). Every
earlier uncapped run that corrupted the metrics had used `arrivalRate`, whose
bursts forced a second sandbox — so smoothing the arrivals removed the
measurement artifact as well as the throttling.

Read `lambda_cw_concurrency_max` before trusting any Lambda `app_*` number: **1
means the scrape saw everything; anything higher means it did not.** The
dashboard shows this panel next to the mode banner for exactly this reason.

Use CloudWatch for Lambda in Experiment B. It aggregates across sandboxes and is
what production practice relies on:

```bash
# Duration (ms): avg and max across all sandboxes
aws cloudwatch get-metric-statistics --namespace AWS/Lambda \
  --metric-name Duration --dimensions Name=FunctionName,Value=<fn> \
  --start-time <ISO> --end-time <ISO> --period 60 --statistics Average Maximum

# Also: Invocations, Throttles, ConcurrentExecutions, Errors
```

Throttles and Errors are separate metrics there, which matters: a throttled
invocation is not a function error, and behind an ALB both surface as HTTP 502.

EC2 and ECS keep their Prometheus `app_*` metrics in both experiments — only
Lambda's collection changes.

### Load phases must stay near or below saturation

One worker at 1 vCPU has a hard throughput ceiling of roughly
`1 / mean_service_time`. Using the duration estimates in
[COSTS.md](./COSTS.md), the committed phase schedule oversaturates every suite:

Artillery's `arrivalRate` counts **virtual users, not HTTP requests**, and each
one runs the whole scenario flow. AniLove's flow is a five-step CRUD cycle
(POST, GET list, GET by id, PUT, DELETE), so its committed rates must be
multiplied by five before being compared to a ceiling in requests per second.
csv-processor and thumbnail-generator issue one request per arrival, so for
those the two coincide. Getting this wrong understates AniLove's real load by
5x:

| Suite | Est. service time | Ceiling at 1 worker | Committed peak `arrivalRate` | Reqs/arrival | Actual peak | Over ceiling |
|-------|------------------|---------------------|------------------------------|--------------|-------------|--------------|
| anilove | ~45 ms (estimate) | ~22 req/s | 50 | **5** | **250 req/s** | **11x** |
| csv-processor | ~175 ms (estimate) | ~5.7 req/s | 28 | 1 | 28 req/s | 4.9x |
| thumbnail-generator | ~290 ms (estimate, later shown ~20x too high, see below) | ~3.4 req/s | 12 | 1 | 12 req/s | 3.5x |

**Those service times were estimates and at least one was badly wrong.** The
csv-processor pilot (2026-08-03) measured mean server-side service time of
**15.51 ms on EC2, 15.54 ms on ECS and 23.44 ms on Lambda** — roughly 11x faster
than the 175 ms assumed above. The real ceiling is therefore ~64 req/s on EC2 and
ECS and **28 req/s on Lambda, which binds**, not 5.7 req/s. The Lambda figure
comes from CloudWatch `Duration`; the in-app timer overstates it as 44 req/s.

The consequence inverts the concern for that suite: its committed peak of 28
req/s was **65% of the ceiling, not 4.9x over it**, so the schedule never reached
saturation at all and would have produced no saturation regime to report. Its
phases are now derived from the measurement:

Ceilings re-measured with smoothed arrivals: **EC2 69 req/s, ECS 67, Lambda 28**
(mean service time 14.39 / 15.02 / 35.8 ms). Lambda binds. Its 35.8 ms is
CloudWatch `Duration`, not the in-app timer's 22.73 ms, the section below
explains why the timer is the wrong basis for a ceiling. The committed
Experiment A schedule:

| Phase | Rate | Duration | Requests | Utilisation (Lambda · EC2/ECS) |
|-------|------|----------|----------|--------------------------------|
| Warm-up | 14 req/s | 3 min | 2,520 | 50% · 20%  (discarded) |
| Probe | 4 req/s | 4 min | 960 | 14% · 6% |
| Probe | 8 req/s | 4 min | 1,920 | 29% · 12% |
| **Primary** | **14 req/s** | **12 min** | **10,080** | **50% · 20%** |
| Probe | 20 req/s | 4 min | 4,800 | 71% · 29% |

27 minutes. The shape is deliberate. The probes give latency **as a function of
load** — how each platform responds as utilisation rises, and where its knee is
— which a single operating point cannot show. The long primary phase keeps
~14,400 requests at the rate the headline figures are quoted at, so its P99
rests on roughly 144 tail samples rather than the handful a uniform sweep would
leave. Probe phases are ample for mean and P95 and thin for P99, which is
exactly why the tail is reported from the primary point only.

Warm-up runs **at** the primary rate rather than below it. Warming lower leaves a
step change at the boundary and the resulting transient falls inside the window
being reported.

The 20 req/s probe sits at 71% of Lambda's ceiling, the closest any Experiment A
phase comes to it. If Lambda shows throttling there while EC2 and ECS do not,
that is a result about how early the no-queue model starts to bite, not a
configuration error — report it rather than tuning the rate down. It did; see
the validation below.

A 60 req/s stress phase was tried and removed: it put EC2 and ECS at 94% of
their own ceiling, where they built 60-second queues and logged ~5000
`ETIMEDOUT` each, while Lambda shed 69%. See "One rate cannot saturate three
platforms" below.

anilove still carries estimated rates and a warning banner in its `test-*.yml`.
Pilot it before its numbers are used.

**thumbnail-generator was rescheduled on 2026-08-05, and again on 2026-08-06
when its fixture changed.** Its service time had never been measured and the
~290 ms estimate above was wrong by roughly 20x, the same inversion
csv-processor hit.

The fixture is now a single 7.1 MP, 0.91 MB JPEG, replacing a 0.5 MP one.
Measured on one workstation under Docker, uncontended, n=719, with the AWS query
params: **77.6 ms mean in-application, of which the sharp pipeline is 76.9**.
Framework overhead is therefore 0.8 ms, which is the evidence that this workload
measures the native library rather than Express. csv-processor's c6i.large pilot
gives a workstation factor of 1.354x, putting thumbnail near 57 ms on c6i and
its EC2/ECS ceiling near 17 req/s.

For Lambda the two models that agreed on the previous fixture now diverge by
almost a factor of two. Carrying csv-processor's Lambda penalty across as a
factor (x2.49) gives 143 ms and a 7 req/s ceiling; as a constant (+21.4 ms) it
gives 79 ms and 13 req/s. Fixed invocation overhead weighs proportionally less
on a 57 ms workload than on a 14 ms one, and the 0.91 MB upload must be
base64-decoded inside the invocation, a cost that scales with payload and that
csv-processor's 533 KB pays less of. The lower bound is used: warm-up and
primary at **3 req/s**, probes at **1, 2 and 5**, which holds csv-processor's
utilisation shape (14%, 29%, 43%, 71% of the binding ceiling). 5,580 arrivals
over 33 minutes.

That is a derivation, not a pilot. `make pilot-thumbnail` is what resolves the
disagreement above, and if the ceiling proves to be 13 rather than 7 the primary
should double to 6 req/s.

**The lower ceiling costs tail samples.** The primary phase yields 2,160
requests against csv-processor's 10,080, so its P99 rests on roughly 22 tail
samples rather than 100, while its P95 still rests on ~108. Extending the
primary from 12 to 30 minutes recovers the tail at the cost of an
18-minute-longer run. The current schedule does not, so a thumbnail P99 is
weaker than a csv-processor one and captions should not imply otherwise.

**Upload size is capped at 1 MB by the load balancer, not by the application.**
An ALB target group backed by a Lambda function rejects request bodies above
1 MB, while EC2 and ECS have no such limit. An oversize fixture therefore fails
on one platform only, and the loss reads as a platform result rather than as a
transport limit. Four candidate fixtures between 1.5 and 5.5 MB were discarded
for this reason; multer's own 5 MB limit applies everywhere and binds later.
`upload-image.js` checks both at load time rather than mid-run.

Its probes run 360 s rather than csv-processor's 240 s. Dashboard panels read
`rate(...[5m])`, so nothing inside a 240 s phase can be read without pulling in
the neighbouring one. csv-processor's probes still have this; its primary does not.

**Validation of the schedule (csv-processor, 2026-08-04, Experiment A).** The
schedule above was run end to end at `reserved_concurrency = 1` to check that
the primary phase is clear of saturation. Lambda rejections by phase:

| Phase | Requests | HTTP 502 | Loss |
|-------|----------|----------|------|
| Warm-up 14 req/s | 2,439 | 9 | 0.4% |
| Probe 4 req/s | 1,018 | 0 | 0% |
| Probe 8 req/s | 1,897 | 0 | 0% |
| **Primary 14 req/s** | **10,045** | **33** | **0.3%** |
| Probe 20 req/s | 4,766 | 452 | 9.5% |

EC2 and ECS returned 20,280 of 20,280 across the whole run. Two things follow.
The primary phase loses 0.3%, so Lambda's headline latency is measured over
99.7% of its requests and carries no survivorship caveat — the earlier 20 req/s
primary lost around 15%, which would have qualified every Lambda row. And the
knee is visible: at 71% utilisation loss rises to 9.5%, which is the reportable
finding about the no-queue model rather than a defect.

The same schedule was then run uncapped (Experiment B, run `20260804-151525`).
The difference between the two is attributable to the concurrency limit alone,
because the arrival schedule is identical:

| Phase | Capped loss | Uncapped loss |
|-------|-------------|---------------|
| Warm-up 14 req/s | 0.4% | **0%** |
| Probe 4 req/s | 0% | 0% |
| Probe 8 req/s | 0% | 0% |
| Primary 14 req/s | 0.3% | **0%** |
| Probe 20 req/s | 9.5% | **0%** |

Uncapped Lambda served **20,280 of 20,280** with zero 502s and, per CloudWatch,
zero throttles in every five-minute bucket of the run — against 508 throttles
capped. It did so at a peak concurrency of **3**, which is the whole finding:
the 9.5% lost at 20 req/s was not a capacity limit but the absence of a queue,
and two extra sandboxes erase it.

Client-side latency barely moves between the two: mean 59.1 ms capped against
61.4 ms uncapped, P99 85.6 against 87.4. Elasticity buys availability here, not
speed, because no phase approached the per-sandbox service rate.

Run entirely above the ceiling and the result is queueing on EC2/ECS versus
rejection on Lambda, not per-request cost. csv-processor's schedule is measured
and thumbnail-generator's is derived; **anilove still carries the rates written
for the retired `t2.micro` / `t3.small` pair and must be re-derived before any
run whose numbers reach the paper**, and its `test-*.yml` carry a warning banner
until it is.

The pilot is tooled:

```bash
make pilot-configs      # generate pilot-*.yml from test-*.yml (sync-targets also does this)
make pilot-csv          # ~7 min at ~35% of the estimated ceiling; also pilot-anilove, pilot-thumbnail
```

Read mean service time per platform over the phase-2 window only — the first
60 s absorbs cold starts and JIT and must be excluded — then set:

```
ceiling = 1000 / mean_ms   (using the slowest platform)
steady  = 0.65 * ceiling   stress = 1.2-1.5 * ceiling
```

Apply the same numbers to all three `test-*.yml` of that suite. Only the steady
figure is used; every phase stays below the slowest platform's ceiling. If the
pilot itself did not return ~100% 2xx, its rate must come down before the reading
is usable.

### Smooth the arrivals: use arrivalCount, not arrivalRate

`arrivalRate: N` starts N virtual users at essentially the same instant each
second rather than spacing them across it. A container absorbs that burst in its
socket backlog; a Lambda sandbox at reserved concurrency 1 has no queue at all,
so the second arrival in each burst is rejected outright.

Measured on csv-processor at 12 req/s with `reserved_concurrency = 1`, control
and test back to back, same 1800 requests at the same mean rate:

| Arrival process | HTTP 200 | HTTP 502 | CloudWatch throttles | Errors |
|-----------------|----------|----------|----------------------|--------|
| `arrivalRate: 12` | 1566 | **234** | **147** | 0 |
| `arrivalCount: 1800` | **1797** | **3** | **3** | 0 |

A ~78x reduction from changing only the arrival process. Zero function errors in
both: every failure was a concurrency rejection.

This retro-explains the earlier runs - 20.4%, 15.4% and 15.4% at 2 req/s, and
69% at 60 req/s - none of which were Lambda being slow. It also matches the
result from the opposite direction: uncapping Lambda absorbed the identical
bursts with **one extra sandbox**.

The consequence is that `reserved_concurrency = 1` is defensible after all. It
cannot be driven by a bursty generator, but with smoothed arrivals it yields
strict equal capacity *and* a clean latency comparison - no handicap to explain
to a reviewer, and no double-digit error rate contaminating the headline table.
All `test-*.yml` and `pilot-*.yml` phases use `arrivalCount`.

### Lambda's ceiling comes from CloudWatch Duration, not the in-app timer

A Lambda concurrency slot is held for the whole invocation, including runtime
overhead outside the handler. The in-app timer measures only the handler, so a
ceiling derived from it is optimistic:

| Source | csv-processor mean | Implied ceiling |
|--------|--------------------|-----------------|
| `app_total_execution_time_seconds` | 22.7 ms | 44 req/s |
| **CloudWatch `Duration`** | **35.8 ms** | **28 req/s** |

Measured throttling at reserved concurrency 1, smoothed arrivals, matches the
CloudWatch figure and not the in-app one:

| Rate | Utilisation vs 28 req/s | Loss |
|------|-------------------------|------|
| 5 req/s | 18% | 0% |
| 10 req/s | 36% | 0% |
| 20 req/s | 71% | 9.5-15% |
| 30 req/s | 107% | ~50% |

The 20 req/s figure spans two runs: 9.5% over a 4-minute probe and ~15% over a
12-minute phase, the longer exposure accumulating more overlaps.

At 71% utilisation ordinary arrival jitter is enough to produce overlaps, and a
sandbox at concurrency 1 rejects rather than queues. Above 100% the loss is
arithmetic. EC2 and ECS are unaffected either way, because they queue - their
ceiling can be taken from either measure.

The primary operating point is therefore set at half of Lambda's CloudWatch
ceiling, so its latency is not measured over surviving requests only.

An earlier revision of this document attributed the same throttling to
coincidence between the three concurrent load streams. That was incorrect: the
three suites address different ALB target groups and do not contend. The cause
is per-stream utilisation against a ceiling that had been overstated.

### One rate cannot saturate three platforms

Measured ceilings differ by a factor of 2.5: EC2 69 req/s, ECS 67, Lambda 28. A
shared stress rate therefore lands somewhere different on each. At 60 req/s EC2 and ECS
sat at 94% of their own ceiling and built 60-second queues, logging ~5000
`ETIMEDOUT` apiece, while Lambda shed 69% of requests. That measures the
queueing model, not the compute model.

Every phase therefore stays below every ceiling: warm-up, steady and soak, and
no stress phase. The strongest evidence the campaign carries for the no-queue
model is the 20 req/s probe, where capped Lambda sheds 9.5% while EC2 and ECS
stay at zero.

### Re-tune the latency buckets from the same pilot

**Do this in the same step as the phase rates — it is not optional, and it
cannot be fixed afterwards.** `histogram_quantile` interpolates linearly inside
whichever bucket the quantile falls into, and latency is not uniformly
distributed inside a bucket, so a wide bucket yields a systematically wrong P95.
The resolution is lost at observation time; no PromQL can recover it.

The committed edges are too coarse where each workload's latency actually sits:

| App | Edges bracketing the expected P95 | Bucket width |
|-----|-----------------------------------|--------------|
| thumbnail-generator | `0.5` → `1` | **500 ms** |
| anilove | `0.1` → `0.25` | 150 ms |
| csv-processor | `0.3` → `0.5` | 200 ms |

A P95 of ~700 ms on thumbnail is being interpolated across a half-second-wide
bucket, which is a larger error bar than any difference between platforms the
paper is likely to report.

From the pilot, take each platform's P50 and P99 for the suite, then edit
`buckets` for `app_total_execution_time_seconds` and
`app_internal_processing_time_seconds` so that:

- at least 5-6 edges fall between the fastest platform's P50 and the slowest
  platform's P99 — that is the range where the quantiles land;
- no bucket in that range is wider than about 25% of the P95 itself;
- the last finite edge is above the slowest platform's worst case, so nothing
  lands in `+Inf`;
- **the edges are identical for all three platforms**, which they are
  automatically, since the three platforms share one source file.

Edit them in `apps/anilove/src/metrics.js`, `apps/csv-processor/app/metrics.py`
(`TOTAL_BUCKETS` / `INTERNAL_BUCKETS`) and
`apps/thumbnail-generator/src/metrics.js`, then rebuild and push the images —
buckets are baked into the image, so a change requires `make push-images` and a
`terraform apply`, not just a restart. Record the final edges in the paper:
bucket boundaries are part of how a reported percentile was obtained.

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
| `app_internal_processing_time_seconds` | The workload alone: anilove minus PostgreSQL wait, csv-processor's `process_csv`, thumbnail's sharp pipeline |
| `app_cold_start_duration_seconds` | Runtime init to first invocation; Lambda only, once per container |
| `app_cpu_seconds_total` | Cumulative process CPU time; **the metric CPU is reported from** |
| `app_cpu_usage_percent` | Process CPU utilisation — diagnostic only, not comparable across platforms (see below) |
| `app_ram_peak_mb` | Peak resident memory since process start (see note on thumbnail-generator below) |
| `artillery_rates{metric="http_request_rate"}` | Throughput, client-side |
| `artillery_summaries` 2xx ratio | Error rate, client-side |

**What the timer covers.** app_total_execution_time_seconds starts inside the
handler, after the framework has buffered the request body. Upload time is
therefore excluded on every app, which keeps the client network path out of the
platform comparison - the 533 KB csv upload contributes generator bandwidth but
not measured time. Client-side latency from the Artillery report includes it,
which is why the two differ by roughly the round trip.

Where it *stops* differs. csv-processor stops when the route handler returns, so
download time is excluded. thumbnail-generator stops on response finish, putting
the socket write inside the measurement: sub-millisecond against ~14 ms, but not
zero, and serverless-express buffers on Lambda where EC2 and ECS write to a
socket. Buffering the output to make the boundary uniform would change the memory
profile, which is also reported, so the asymmetry is the smaller distortion.


The difference between the first two is time waiting on the database. AniLove
tracks it with `AsyncLocalStorage` fed by Sequelize's `benchmark` logger, which
is what separates platform overhead from application work.

More metrics are instrumented than the paper reports
(`app_cpu_peak_percent`, `app_ram_usage_mb`, client-side latency, host-level

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

# CPU cost per request, in CPU-milliseconds. This is the CPU figure to report.
1000 * sum by (instance) (rate(app_cpu_seconds_total[5m]))
     / clamp_min(sum by (instance) (rate(app_total_execution_time_seconds_count[5m])), 1e-9)

# Resources and load
max by (instance) (max_over_time(app_ram_peak_mb[5m]))
avg by (service) (artillery_rates{metric="http_request_rate"})

# Error rate (%)
100 * (1 -
  sum by (service) (artillery_summaries{metric="http_response_time_2xx_count"})
  / sum by (service) (artillery_summaries{metric="http_response_time_count"})
)
```

### Lambda's app_* series is per-container, so Experiment B reads from CloudWatch

Why this happens, and the threshold at which it starts, are covered under
[Two experiments, not one](#two-experiments-not-one): the condition is the
sandbox count, not the cap. This section records what it does to each reported
quantity, and what to substitute.

Measured during the 14 req/s primary phase of the Experiment B run, at a peak
concurrency of 3, against a generator sending exactly 14 req/s to each platform:

```promql
rate(app_total_execution_time_seconds_count[2m])
  ec2 14.00    ecs 14.00    lambda 232.14
```

EC2 and ECS report the arrival rate. Lambda overstates it 16x. What survives and
what does not:

| Quantity | Uncapped Lambda |
|----------|-----------------|
| Rate of a counter alone | **Invalid** — the 232 above |
| Mean and quantiles (`_sum/_count`, `histogram_quantile`) | Biased: numerator and denominator move together, so the value is roughly the answering container's lifetime distribution rather than the query window |
| CPU per request | Usable — both counters come from the same scrape of the same container, so the jumps cancel |
| `app_ram_usage_mb`, `app_ram_peak_mb` | Usable — gauges, and per-container memory is the intended reading |


## Reading the results correctly

**Percentiles do not subtract.** `P95(total) - P95(internal)` is not the
95th-percentile database wait, because the request at the 95th percentile of
total time is generally not the one at the 95th percentile of internal time.
Only means are additive, so the database-wait figure is mean-based.

**CPU utilisation is not comparable across platforms; CPU per request is.**
A percentage is CPU seconds per wall second, which is well defined for a
process that is always running — what EC2 and ECS provide — but not for a
Lambda sandbox, which is frozen between invocations. Wall time keeps advancing
while CPU time does not, so `app_cpu_usage_percent` is diluted toward zero on
Lambda by however idle the function happened to be, making it look cheaper in
CPU as a pure artefact. Sampling per request instead avoids the freeze but
counts process-wide CPU against one request's wall time, so concurrent requests
inflate it.

`app_cpu_seconds_total` is a counter and has neither problem. Divided by the
request count over the same window it gives CPU seconds per request, which is
freeze-immune (a frozen sandbox accrues no CPU and serves no requests) and
concurrency-safe (numerator and denominator cover the same window). The three
percentage gauges are still exported for live diagnosis and should not be
published; the csv and thumbnail dashboards no longer plot them.

**Cold start buckets are shared across the three applications.** All three use
the same edges (`0.1 … 12 s`, dense over 0.25-3 s), so cold start is comparable
between workloads and not only between platforms. A quantile falling in the
`+Inf` bucket cannot be interpolated, so the ceiling must exceed the slowest
real cold start. Lambda image sizes as pushed: csv-processor 251 MB (pandas and
numpy), thumbnail-generator 155 MB (sharp), anilove 147 MB — so csv-processor
is the one that sets the requirement, not thumbnail-generator.

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
make lock-deps            # pins the transitive Python closure; commit the result
make push-images
make sync-targets         # fills the REPLACE_ME targets from terraform outputs
make ecs-up
make validate-aws         # every target healthy, not just one
make validate-fairness    # metric names, CPU pins, deployed specs
make bench-anilove        # Prometheus + Grafana; also bench-csv, bench-thumbnail
                          # metrics-proxy not needed: the ALB hostnames resolve
make validate-bench       # config check before a 30+ minute run
make artillery-anilove    # EC2 + ECS + Lambda in parallel
make loadgen-sync         # pull the reports down - destroy deletes the bucket
make ecs-down             # or make destroy
make validate-teardown    # confirm nothing billable survived
```

A full session costs roughly US$ 7 and takes about 8 hours including setup and
teardown. See [COSTS.md](./COSTS.md).

### Build reproducibility

A benchmark whose images resolve different library versions on each build
measures a moving target. Three things are pinned so that a rebuild months later
produces the same binaries:

| What | How |
|------|-----|
| Node dependencies | `package-lock.json` committed for both Node apps; images build with `npm ci`, which installs exactly the locked tree and fails if it disagrees with `package.json` |
| Python dependencies | Direct versions pinned in `requirements.txt`; run `scripts/lock-python-deps.sh` to pin the transitive closure too |
| Base images | All four `FROM` lines pinned by `sha256:` digest, not by tag |

The versions in use are recorded below. `sharp` and `numpy` deserve the
attention: each *is* the cost of its workload, so a version change is a change
to what the paper measures, not an implementation detail.

| App | Key locked versions |
|-----|---------------------|
| anilove | express 5.2.1, sequelize 6.37.8, pg 8.22.0, bcrypt 6.0.0 |
| thumbnail-generator | **sharp 0.34.5**, express 5.2.1, multer 2.2.0 |
| csv-processor | pandas 2.3.1, fastapi 0.116.0, psutil 6.1.1 (numpy pinned by the lock script) |

Note that `sharp` resolved to 0.34.5 even though `package.json` requests
`^0.34.4` — that one-patch drift, on the single library the thumbnail workload
is built around, is exactly what the lockfile now prevents.

Base image digests, resolvable with
`docker buildx imagetools inspect <image> --format '{{.Manifest.Digest}}'`:

| Image | Digest |
|-------|--------|
| `node:22-slim` | `sha256:f32b8106…0ffdc46` |
| `python:3.12-slim` | `sha256:57cd7c3a…6317710de` |
| `public.ecr.aws/lambda/nodejs:22-x86_64` | `sha256:b37cb622…8e562ed85` |
| `public.ecr.aws/lambda/python:3.12-x86_64` | `sha256:ec6a76e8…c289592cc` |

Debian-based `node:22-slim` is used rather than Alpine because the Lambda base
image is glibc, and native modules such as `sharp` and `bcrypt` ship different
prebuilt binaries per C library. Matching libc keeps the compute model the only
difference between platforms.

### How many repetitions

**Ten capped plus three uncapped, per workload — 13 runs each, 39 in total.**
Revised upward from five on 2026-08-08.

| Runs | Config | Schedule |
|------|--------|----------|
| 10 | capped, `reserved_concurrency = 1` | committed `test-*.yml` |
| 3 | uncapped, `-1` | the same `test-*.yml` |

Ten sessions carry all of it: sessions 1-7 run capped only, sessions 8-10 run
capped, then flip the one tfvars line, `make apply` (Lambda only, ~5 min) and run
again uncapped.

Why ten. Ranking three platforms with Friedman on `n` blocks gives, at perfect
separation, exactly `chi2 = 2n` and so `p = e^-n`. The minimum achievable p is
fixed by the number of runs alone: n=2 cannot reach significance at all
(p=0.135), n=3 only just does (0.0498), n=5 gives 0.0067, and n=10 gives
0.000045 (enough margin to lose a run to a failed teardown and still be clear).

**Never trade breadth for depth.** If the schedule slips, five repetitions on all
three workloads beats ten on one and none on the others: the paper's claim is
about three *bottleneck types*, and a study of one CPU-bound workload is a
different, narrower paper.

Run each repetition on **freshly provisioned instances** (`make destroy` then
`make apply`), not back to back on the same stack. This also gives every
repetition fresh Lambda containers, so each one contributes new cold-start
samples — the metric that benefits most from repetition, since its *n* is the
number of cold containers rather than the number of requests.

Two things that cycle will bite. The load generator's S3 bucket has
`force_destroy`, so **each destroy deletes the previous repetition's reports**:
run `make loadgen-sync` before tearing down, and `make validate-teardown`, which
refuses to pass quietly while the bucket still holds objects. And a destroy that
half-fails leaves instances billing while `terraform state list` looks clean, so
confirm each teardown against AWS rather than against state.

Aggregate as **median and IQR across runs, not mean and standard deviation**:
latency distributions are right-skewed and normality cannot be demonstrated at
n=10. Compute the per-run statistic first, then aggregate. The median across ten
runs of each run's P95 is a valid quantity; the mean of ten P95 values is not — a
percentile is a quantile of a distribution and averaging quantiles from ten
different distributions yields a quantile of nothing. Captions must say which was
used. Prefer IQR over min-max at this n: min-max widens as n grows, so it is not
comparable across cells with different run counts.

Present it as: bars at the median with IQR whiskers for the latency figures, one
representative run for the phase time series (averaging across runs smears the
phase boundaries), and median [Q1, Q3] per cell in the results table. Report
error rate in the *same* table as latency, never separately.

If a statistical claim is needed, the test is **Friedman**. The three platforms
are loaded concurrently in one time window, so a run is a *block* and the three
observations within it are paired rather than independent. Friedman is the
matching test for that design, and it removes between-run variance instead of
dumping it into the error term. Post-hoc: Nemenyi, or pairwise Wilcoxon
signed-rank with Bonferroni. Report the **ratio of medians** as effect size —
"Lambda is 3.1x EC2" is what a reader remembers; a p-value only says the
difference is not noise.

`make aggregate-csv|anilove|thumbnail` does all of this: per-run statistics over
one phase window, then median [Q1, Q3] across runs split by capped/uncapped, plus
the Friedman test and effect size. No Python or R required.

**One limitation this analysis inherits.** Artillery's JSON keeps only a summary
per 10 s period, not raw histogram buckets, so an exact percentile over a phase
window cannot be reconstructed from the run reports. Mean, counts, min and max
are exact; the p50/p95/p99 it reports are count-weighted means of the per-period
percentiles. Either label them as such, or take tail latency from the Prometheus
`app_*` histograms with `histogram_quantile` over the same window — which
requires snapshotting the TSDB before `make bench-down-*`, since the container
dies with the stack.

The repository ships with Artillery targets set to `https://REPLACE_ME` and
with empty Prometheus scrape targets for the csv and thumbnail suites.
`make sync-targets` fills the former; the latter are filled manually per
[PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md).

## Limitations

- **The database is shared.** One `db.m6g.large` serves AniLove on all three
  platforms; `DB_SCHEMA` isolates data, not load. Concurrent runs contend for
  the same CPU and IOPS, and that contention is part of the measured database
  wait.
- ~~**Transitive Python dependencies are not locked yet.**~~ Closed.
  `apps/csv-processor/requirements.txt` is now a full transitive closure pinned
  exactly (`numpy==2.5.1`), generated by `scripts/lock-python-deps.sh` and
  resolved inside the same digest-pinned base image the Dockerfile builds from.
  `make validate-fairness` asserts it. All three applications are now fully
  pinned, so dependency drift is no longer a threat to validity.
- **Half of each host is idle.** `c6i.large` has 2 vCPUs and the container is
  capped at 1, because no 1-vCPU non-burstable type exists. Results therefore
  describe an application confined to one vCPU on an otherwise unloaded host,
  not a fully packed instance.
- **Every phase sits below the slowest platform's service rate.** The uncapped
  runs remove the concurrency limit but keep the same arrival schedule, so they
  isolate the cost of the cap. Behaviour of an overloaded platform is outside the
  measured scope.
- **One region, and however many repetitions were performed.** All numbers come
  from ap-northeast-1. A single run per configuration supports no claim about
  variance.
- **Lambda is measured at lower resolution than EC2 and ECS, and from a
  different source in Experiment B.** Its application metrics come from whichever
  sandbox answers the scrape, which is exact at concurrency 1 and not
  fleet-representative above it, so uncapped latency is taken from CloudWatch
  `Duration` instead. Its scrape interval is also 30 s against 5 s elsewhere,
  because the scrape competes with the workload for a concurrency slot. See
  [the section above](#lambdas-app_-series-is-per-container-so-experiment-b-reads-from-cloudwatch).
- **The ALB terminates TLS.** `benchcomp.click` is registered and delegated to
  Route 53, so ACM issues one wildcard certificate and the listener serves HTTPS
  on 443, with port 80 redirecting to it. Target groups are selected by
  hostname, one per app and platform, all covered by that certificate. Because
  `lambda_behind_alb = true` puts all three platforms behind the same listener,
  the handshake cost is paid *equally* and sits outside the in-application
  timer. It does appear in client-side latency, which is what a TLS-terminating
  deployment would show.

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
