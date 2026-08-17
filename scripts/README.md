# Scripts (bash + Node only)

All automation lives here or under `benchmarks/scripts/`.

On Windows use **Git Bash** or **WSL**.

### Checks

| Script | Purpose |
|--------|---------|
| `check-prereqs.sh` | Verify aws, docker, terraform, node, bash |
| `validate-terraform.sh` | Pre-apply: fmt, validate, backend wiring, tfvars, ECR images vs `enable_*` |
| `validate-benchmark-config.sh` | Pre-run: Artillery targets/Host headers/pushgateway ports, Prometheus jobs, compose ports |
| `validate-aws-state.sh` | Post-apply: target-group health, ECS counts, EC2 status checks, Lambda, RDS |
| `validate-fairness.sh` | Only-compute-varies: shared metric names, 1-vCPU pins, deployed specs, live `/metrics` |
| `validate-teardown.sh` | Post-destroy: asks AWS, not Terraform, whether anything billable under the project prefix survived |
| `health-check.sh` | `/health` for ALB hosts + Lambda URLs |

### Deploy

| Script | Purpose |
|--------|---------|
| `push-ecr.sh` | Build and push app images to ECR; pins every digest in `terraform/image-digests.auto.tfvars` |
| `lock-python-deps.sh` | Pin the transitive Python closure, resolved inside the same digest-pinned base image the Dockerfile builds from. Run before `push-ecr.sh` |
| `sync-artillery-targets.sh` | Fill Artillery and Prometheus targets from `terraform/generated/benchmark-targets.json` |
| `make-pilot-configs.sh` | Generate `pilot-*.yml` from each committed `test-*.yml`, replacing only the phases block with a short probe below saturation |
| `ecs-scale.sh` | Scale ECS services and ASG (`up` / `down` / `status`) |
| `db-reset.sh` | Truncate and reseed the AniLove schemas before a repetition. Goes through SSM to the EC2 instance, since RDS admits no workstation. `--count` reports rows and changes nothing |

### Running load

| Script | Purpose |
|--------|---------|
| `loadgen-sync.sh` | Stage the suites onto the in-region generator, via S3. Uploads only — the generator runs what was last synced, not the working tree |
| `loadgen-run.sh` | Run one suite's three platforms concurrently on the generator, then download the reports into the suite's `artillery/logs/` |
| `run-manifest.sh` | Snapshot git SHA, AMIs, image digests and config next to a run's logs |
| `metrics-proxy.js` | Host proxy for EC2/ECS scrapes on an HTTP-only ALB; exits when a domain is set |

Both runners — `benchmarks/scripts/run-parallel.sh` and `loadgen-run.sh` — call
these two when a run ends. The `publish-metrics` plugin alone pushes only its
last reporting interval and never the 4xx/5xx counts.

| Script | Purpose |
|--------|---------|
| `push-artillery-report.js` | Push the client-side series from the JSON report into the suite's pushgateways |
| `push-lambda-cloudwatch.js` | Push Lambda's CloudWatch series (Duration, Invocations, Throttles, Errors, Init Duration) into the lambda pushgateway. Authoritative whenever Lambda runs more than one sandbox |

### Analysis

Run `capture-*` **before** `bench-down-*` or `destroy`: the split of service time
into compute and database wait lives only in Prometheus, which dies with the
suite's compose stack.

| Script | Purpose |
|--------|---------|
| `capture-app-metrics.js` | Write one run's Prometheus `app_*` means to disk as `app-metrics-<run-id>.json` |
| `aggregate-runs.js` | Median [Q1, Q3] and Friedman across repetitions; writes `per-run.csv` |
| `make-figures.js` | Phase time series for one representative run, as `.tex` (pgfplots) + `.svg` |
| `make-db-wait-figure.js` | AniLove latency split into in-app compute, database wait, and time outside the application |
| `make-condition-figure.js` | Capped versus uncapped per platform. Reads `per-run.csv`, so run `aggregate-runs.js` first |

`lib.sh` holds shared helpers and is sourced, never executed.

## Typical flow

```bash
make check
make validate-tf     # before apply
make apply
make push-images
make sync-targets
make health
make ecs-up
make validate-aws       # every target healthy, not just one
make validate-fairness  # only the compute model varies
make bench-anilove
make metrics-proxy      # HTTP-only stacks; no-op with a domain
make validate-bench     # before the 17.5 minute run
make db-reset           # truncate and reseed the anilove schemas
make loadgen-sync       # stage the suites onto the in-region generator
make loadgen-anilove    # the run itself; artillery-anilove runs it from here
make capture-anilove RUN=<run-id>   # app_* to disk while Prometheus is up
make ecs-down           # or make destroy when done
make validate-teardown  # after a destroy
```

Then, once the repetitions are in:

```bash
make aggregate-anilove          # median [Q1, Q3] + Friedman, writes per-run.csv
make figure-anilove RUN=<run-id>
make figure-split-anilove       # compute / db wait / overhead
make figure-condition-anilove   # capped vs uncapped; needs per-run.csv
```

`validate-terraform.sh` and `validate-fairness.sh` skip their AWS checks when no
credentials resolve; pass `--offline` to skip them deliberately.
`validate-fairness.sh --no-scrape` keeps the deployed checks but skips the live
`/metrics` pull. Every script in the Checks table is read-only.

## Make aliases

See `make help` at the repo root.
