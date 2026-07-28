# Parallel Artillery (EC2 + ECS + Lambda) for charts

Run the three platform load tests in the same wall-clock window for side-by-side Grafana charts.

There are two levels of "parallel":

1. **Within one suite:** EC2 + ECS + Lambda Artillery together (required for aligned platform charts).
2. **Across suites:** AniLove + CSV + Thumbnail metrics stacks together (optional; different host ports).

```text
                    +--> EC2 app     --> Prometheus (instance=ec2)
Artillery x3 -------+--> ECS app     --> Prometheus (instance=ecs)
  (same start)      +--> Lambda app  --> Prometheus (instance=lambda)
         |
         +--> pushgateway (suite-specific host port)
                              v
                    Grafana (suite-specific host port)
```

---

## Prerequisites

1. Apps deployed on EC2, ECS, and Lambda (URLs in `test-*.yml`). Source: `apps/<name>/`.
2. AniLove: shared RDS, `DB_SCHEMA=ec2|ecs|lambda`, TLS on.
3. Metrics stack for the suite(s) under test:

```bash
make bench-anilove      # and/or bench-csv, bench-thumbnail
```

4. Node/npm available (`npx` pulls Artillery `2.0.23`).
5. CSV and Thumbnail only: `npm install` once under the suite `artillery/` folder if `form-data` is missing.

Host ports: [benchmarks/docs/PORTS.md](../benchmarks/docs/PORTS.md).  
Shared runner: [benchmarks/scripts/](../benchmarks/scripts/).

---

## Host ports (summary)

| Suite | Prometheus | Grafana | PG ECS | PG EC2 | PG Lambda |
|-------|------------|---------|--------|--------|-----------|
| AniLove | 9090 | 3002 | 9092 | 9093 | 9094 |
| CSV | 9190 | 3102 | 9192 | 9193 | 9194 |
| Thumbnail | 9290 | 3202 | 9292 | 9293 | 9294 |

Artillery YAML files use the matching pushgateway URLs.

---

## Run (Windows)

```bat
cd benchmarks\suites\anilove\artillery
run-parallel.bat

cd benchmarks\suites\csv-processor\artillery
run-parallel.bat

cd benchmarks\suites\thumbnail-generator\artillery
run-parallel.bat
```

Logs: `artillery\logs\`.

---

## Run (Linux / macOS)

```bash
cd benchmarks/suites/anilove/artillery
chmod +x run-parallel.sh
./run-parallel.sh
# same pattern under suites/csv-processor and suites/thumbnail-generator
```

Or from repo root:

```bash
make artillery-anilove
make artillery-csv
make artillery-thumbnail
```

---

## File names (aligned across suites)

| File | Platform |
|------|----------|
| `test-ec2.yml` | EC2 |
| `test-ecs.yml` | ECS |
| `test-lambda.yml` | Lambda |

---

## Grafana

1. Open the suite Grafana URL (see table above).
2. Set the time range to the parallel run duration.
3. Split series by `instance` (`ec2` / `ecs` / `lambda`).
4. Import `grafana/dashboard.json` from the suite folder if needed.

Login (AWS suites): `admin` / `123`.

---

## Concurrent suites + concurrent platforms

Example: load-test all three apps at once, each with EC2/ECS/Lambda in parallel:

```bash
make bench-anilove && make bench-csv && make bench-thumbnail

# three terminals (or background jobs)
make artillery-anilove
make artillery-csv
make artillery-thumbnail
```

Then open Grafana on ports 3002, 3102, and 3202.

---

## Notes

- Within one suite, start EC2 + ECS + Lambda Artillery together for aligned charts.
- Suites may run together because host ports do not overlap ([PORTS.md](../benchmarks/docs/PORTS.md)).
- Parallel AniLove load shares RDS CPU/IOPS; schemas isolate data.
- Local path (`local/`): single stack, not three AWS platforms. Shares AniLove ports (9090/3002/9092-9094); do not start `benchmarks/suites/anilove` at the same time as `make local-up`.
