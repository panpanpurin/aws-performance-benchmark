#!/usr/bin/env bash
# Shared parallel Artillery runner for EC2 + ECS + Lambda.
#
#   ./benchmarks/scripts/run-parallel.sh anilove
#   ./benchmarks/scripts/run-parallel.sh anilove pilot   # short, under-saturated
#   make artillery-anilove
#
# Prerequisite: metrics stack up (make bench-anilove, etc.)
#
# Pilot mode runs pilot-*.yml: a short run below the ceiling to measure service
# time before committing to a full schedule. See scripts/make-pilot-configs.sh.
set -euo pipefail

SUITE="${1:-}"
MODE="${2:-test}"
if [[ -z "$SUITE" ]]; then
  echo "Usage: $0 <anilove|csv-processor|thumbnail-generator> [pilot]" >&2
  exit 1
fi
case "$MODE" in
  test)  PREFIX="test" ;;
  pilot) PREFIX="pilot" ;;
  *)
    echo "Unknown mode: $MODE (expected 'pilot' or nothing)" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ART_DIR="$ROOT/benchmarks/suites/$SUITE/artillery"

if [[ ! -d "$ART_DIR" ]]; then
  echo "Unknown suite or missing artillery dir: $ART_DIR" >&2
  exit 1
fi

case "$SUITE" in
  anilove)
    TITLE="AniLove"
    PROM="http://localhost:9090"
    GRAF="http://localhost:3002"
    PG="9092 / 9093 / 9094"
    MAKE_HINT="bench-anilove"
    ;;
  csv-processor)
    TITLE="CSV Processor"
    PROM="http://localhost:9190"
    GRAF="http://localhost:3102"
    PG="9192 / 9193 / 9194"
    MAKE_HINT="bench-csv"
    ;;
  thumbnail-generator)
    TITLE="Thumbnail"
    PROM="http://localhost:9290"
    GRAF="http://localhost:3202"
    PG="9292 / 9293 / 9294"
    MAKE_HINT="bench-thumbnail"
    ;;
  *)
    echo "Unknown suite: $SUITE" >&2
    exit 1
    ;;
esac

# Prefer global artillery; fall back to npx (works on Windows Git Bash / WSL / Linux)
resolve_artillery() {
  if command -v artillery >/dev/null 2>&1; then
    echo "artillery run"
    return
  fi
  # Common Windows global npm path
  if [[ -x "${APPDATA:-}/npm/artillery.cmd" ]]; then
    echo "\"${APPDATA}/npm/artillery.cmd\" run"
    return
  fi
  if [[ -x "/c/Program Files/nodejs/npx.cmd" ]]; then
    echo "\"/c/Program Files/nodejs/npx.cmd\" --yes artillery@2.0.23 run"
    return
  fi
  if command -v npx >/dev/null 2>&1; then
    echo "npx --yes artillery@2.0.23 run"
    return
  fi
  echo "ERROR: artillery/npx not found. Install Node.js and optionally: npm install -g artillery@2.0.23" >&2
  exit 127
}

ART_RUN="$(resolve_artillery)"
export NPM_CONFIG_LOGLEVEL=error
export NPM_CONFIG_UPDATE_NOTIFIER=false

cd "$ART_DIR"

# form-data is declared in a package.json next to the processors but nothing
# installs it; without it all three die at processor.js with MODULE_NOT_FOUND.
if [[ -f package.json && ! -d node_modules ]]; then
  echo "Installing Artillery helper dependencies for $SUITE ..."
  npm install --no-audit --no-fund --loglevel=error || {
    echo "ERROR: npm install failed in $ART_DIR" >&2
    exit 1
  }
fi

for f in "$PREFIX-ec2.yml" "$PREFIX-ecs.yml" "$PREFIX-lambda.yml"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    [[ "$PREFIX" == "pilot" ]] && echo "Generate the pilots first: bash scripts/make-pilot-configs.sh" >&2
    exit 1
  fi
done

mkdir -p logs
stamp="$(date +%Y%m%d-%H%M%S)"
trap 'echo; echo "Stopping..."; pkill -P $$ 2>/dev/null || true; wait 2>/dev/null || true; exit 130' INT

echo "========================================"
if [[ "$PREFIX" == "pilot" ]]; then
  echo " $TITLE - PILOT (service-time probe, not a measurement run)"
else
  echo " $TITLE - parallel EC2 / ECS / Lambda"
fi
echo " Prerequisite: make $MAKE_HINT"
echo " Prometheus: $PROM"
echo " Grafana:    $GRAF"
echo " Pushgateway ECS/EC2/Lambda: $PG"
echo " Tool:       $ART_RUN"
echo "========================================"
echo
if [[ "$PREFIX" == "pilot" ]]; then
  echo "Pilot takes about 7 minutes. Logs: $ART_DIR/logs"
else
  echo "Full phases can take 30+ minutes. Logs: $ART_DIR/logs"
fi
echo

# --output writes the JSON report push-artillery-report.js reads. The
# publish-metrics plugin only pushes its last reporting interval and never emits
# the 4xx/5xx counts, so without this the error panels stay empty and throughput
# and availability show a 10-second sample instead of the run.
run_start=$(date +%s)

# shellcheck disable=SC2086
eval "$ART_RUN $PREFIX-ec2.yml    --output logs/$PREFIX-ec2-$stamp.json"    > "logs/$PREFIX-ec2-$stamp.log"    2>&1 & pid_ec2=$!
echo "[EC2]    pid=$pid_ec2    -> logs/$PREFIX-ec2-$stamp.log"
# shellcheck disable=SC2086
eval "$ART_RUN $PREFIX-ecs.yml    --output logs/$PREFIX-ecs-$stamp.json"    > "logs/$PREFIX-ecs-$stamp.log"    2>&1 & pid_ecs=$!
echo "[ECS]    pid=$pid_ecs    -> logs/$PREFIX-ecs-$stamp.log"
# shellcheck disable=SC2086
eval "$ART_RUN $PREFIX-lambda.yml --output logs/$PREFIX-lambda-$stamp.json" > "logs/$PREFIX-lambda-$stamp.log" 2>&1 & pid_lambda=$!
echo "[LAMBDA] pid=$pid_lambda -> logs/$PREFIX-lambda-$stamp.log"

status=0
wait "$pid_ec2"    || status=$(( status | 1 )); echo "[EC2] finished (check log if errors)."
wait "$pid_ecs"    || status=$(( status | 2 )); echo "[ECS] finished (check log if errors)."
wait "$pid_lambda" || status=$(( status | 4 )); echo "[LAMBDA] finished (check log if errors)."

if [[ "$status" -ne 0 ]]; then
  echo "One or more failed (bitmask=$status). Tail of logs:" >&2
  for name in ec2 ecs lambda; do
    f="logs/$PREFIX-${name}-$stamp.log"
    if [[ -f "$f" ]]; then
      echo "--- $f (last 15 lines) ---" >&2
      tail -n 15 "$f" >&2 || true
    fi
  done
  exit 1
fi

run_elapsed=$(( $(date +%s) - run_start ))

# Feeds the dashboard's lower two rows. loadgen-run.sh does the same after a
# remote run; repeating is safe, the pushgateway keeps only the latest value.
echo
echo "Publishing client-side metrics ..."
( cd "$ROOT" && node scripts/push-artillery-report.js "$SUITE" "$stamp" ) ||
  echo "WARN could not publish client-side metrics - is 'make $MAKE_HINT' up?" >&2

echo "Publishing Lambda CloudWatch metrics ..."
( cd "$ROOT" && node scripts/push-lambda-cloudwatch.js "$SUITE" "$run_elapsed" ) ||
  echo "WARN could not publish Lambda CloudWatch metrics - check AWS credentials" >&2

echo
if [[ "$PREFIX" == "pilot" ]]; then
  cat <<EOF
Pilot finished. This is not a measurement run - it exists to size the phases.

In Grafana ($GRAF) or Prometheus ($PROM), over the phase-2 window only
(skip the first 60 s), read mean service time per platform:

  1000 * sum by (instance) (rate(app_total_execution_time_seconds_sum[2m]))
       / clamp_min(sum by (instance) (rate(app_total_execution_time_seconds_count[2m])), 1e-9)

Then, using the slowest platform's mean:
  ceiling = 1000 / mean_ms       steady = 0.65 * ceiling       stress = 1.2-1.5 * ceiling

Set those in test-ec2.yml, test-ecs.yml and test-lambda.yml - identical across
all three - before the measurement runs. Check the 2xx ratio was ~100% here; if
it was not, the pilot itself was already saturating and the rate must go lower.
EOF
else
  echo "All parallel tests finished. Open Grafana: $GRAF"
fi
