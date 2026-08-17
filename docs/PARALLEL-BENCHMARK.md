# Parallel Artillery (EC2 + ECS + Lambda)

Run the three platform load tests in the same time window for side by side Grafana charts.

Two levels of parallel:

1. **Within one suite:** EC2 + ECS + Lambda Artillery together (needed for aligned platform charts).
2. **Across suites:** AniLove + CSV + Thumbnail stacks together (optional; different host ports).

```text
                    +--> EC2     --> Prometheus (instance=ec2)
Artillery x3 -------+--> ECS     --> Prometheus (instance=ecs)
  (same start)      +--> Lambda  --> Prometheus (instance=lambda)
         |
         +--> pushgateway (suite host port)
                              v
                    Grafana (suite host port)
```

## Prerequisites

1. Apps on EC2, ECS, and Lambda; real URLs in each `test-*.yml` ([ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md)).
2. AniLove: shared RDS, `DB_SCHEMA=ec2|ecs|lambda`, TLS on.
3. Metrics stack:

```bash
make bench-anilove      # and/or bench-csv, bench-thumbnail
```

4. Node/npm (`npx` pulls Artillery `2.0.23`). Docker Compose **v2.20+**.
5. CSV / Thumbnail: `npm install` once under suite `artillery/` if `form-data` is missing.

| Related | Link |
|---------|------|
| Ports | [PORTS.md](../benchmarks/docs/PORTS.md) |
| Runner | [benchmarks/scripts/](../benchmarks/scripts/) |

## Host ports

| Suite | Prometheus | Grafana | PG ECS | PG EC2 | PG Lambda |
|-------|------------|---------|--------|--------|-----------|
| AniLove | 9090 | 3002 | 9092 | 9093 | 9094 |
| CSV | 9190 | 3102 | 9192 | 9193 | 9194 |
| Thumbnail | 9290 | 3202 | 9292 | 9293 | 9294 |

## Run

### AWS runs: from the in-region generator

This is the path a reported run must take. The phase rates are beyond what a
workstation uplink can supply, and a saturated generator degrades all three
platforms unevenly — which reads as a platform difference rather than as a
broken run. Needs `enable_loadgen = true`.

```bash
make loadgen-sync         # stage the current suites onto the generator
make loadgen-anilove      # or loadgen-csv, loadgen-thumbnail
```

The three platforms run concurrently on the generator and the reports come back
to `benchmarks/suites/<app>/artillery/logs/` when it finishes. `make
loadgen-sync` uploads; it never retrieves results, so re-run it after any edit
to a `test-*.yml`, processor or fixture, and after `make sync-targets`.

Client-side metrics come from those JSON reports, not from the
`publish-metrics` plugin: the pushgateways listen on the workstation and the
generator cannot reach them.

### From this workstation

Fine for local work, smoke tests and pilots against a stack you are still
wiring up. Not for a reported measurement.

```bash
make artillery-anilove
make artillery-csv
make artillery-thumbnail
```

Or per suite:

```bash
cd benchmarks/suites/anilove/artillery
./run-parallel.sh          # Windows: run-parallel.bat
```

Both are thin wrappers around `benchmarks/scripts/run-parallel.sh`.

Logs: `artillery/logs/` under each suite.

| File | Platform |
|------|----------|
| `test-ec2.yml` | EC2 |
| `test-ecs.yml` | ECS |
| `test-lambda.yml` | Lambda |

## Grafana

1. Open the suite Grafana URL (table above).
2. Set the time range to the parallel run duration.
3. Split series by `instance` (`ec2` / `ecs` / `lambda`).
4. Import `grafana/dashboard.json` if needed.

Login (AWS suites): `admin` / `123`.

## All suites at once

```bash
make bench-anilove && make bench-csv && make bench-thumbnail

# three terminals
make artillery-anilove
make artillery-csv
make artillery-thumbnail
```

Grafana: ports 3002, 3102, 3202.

## Notes

- Start EC2 + ECS + Lambda Artillery together within a suite for aligned charts.
- Suites may run together (non overlapping ports).
- Parallel AniLove load shares RDS CPU and IOPS; schemas isolate data.
- Local path (`local/`) is not three AWS platforms. It shares AniLove ports; do not run `benchmarks/suites/anilove` with `make local-up`.
