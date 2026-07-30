#!/usr/bin/env bash
# Shared parallel Artillery runner for EC2 + ECS + Lambda.
#
#   ./benchmarks/scripts/run-parallel.sh anilove
#   make artillery-anilove
#
# Prerequisite: metrics stack up (make bench-anilove, etc.)
set -euo pipefail

SUITE="${1:-}"
if [[ -z "$SUITE" ]]; then
  echo "Usage: $0 <anilove|csv-processor|thumbnail-generator>" >&2
  exit 1
fi

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
for f in test-ec2.yml test-ecs.yml test-lambda.yml; do
  [[ -f "$f" ]] || { echo "Missing: $f" >&2; exit 1; }
done

mkdir -p logs
stamp="$(date +%Y%m%d-%H%M%S)"
trap 'echo; echo "Stopping..."; pkill -P $$ 2>/dev/null || true; wait 2>/dev/null || true; exit 130' INT

echo "========================================"
echo " $TITLE - parallel EC2 / ECS / Lambda"
echo " Prerequisite: make $MAKE_HINT"
echo " Prometheus: $PROM"
echo " Grafana:    $GRAF"
echo " Pushgateway ECS/EC2/Lambda: $PG"
echo " Tool:       $ART_RUN"
echo "========================================"
echo
echo "Full phases can take 30+ minutes. Logs: $ART_DIR/logs"
echo

# shellcheck disable=SC2086
eval "$ART_RUN test-ec2.yml"    > "logs/ec2-$stamp.log"    2>&1 & pid_ec2=$!
echo "[EC2]    pid=$pid_ec2    -> logs/ec2-$stamp.log"
# shellcheck disable=SC2086
eval "$ART_RUN test-ecs.yml"    > "logs/ecs-$stamp.log"    2>&1 & pid_ecs=$!
echo "[ECS]    pid=$pid_ecs    -> logs/ecs-$stamp.log"
# shellcheck disable=SC2086
eval "$ART_RUN test-lambda.yml" > "logs/lambda-$stamp.log" 2>&1 & pid_lambda=$!
echo "[LAMBDA] pid=$pid_lambda -> logs/lambda-$stamp.log"

status=0
wait "$pid_ec2"    || status=$(( status | 1 )); echo "[EC2] finished (check log if errors)."
wait "$pid_ecs"    || status=$(( status | 2 )); echo "[ECS] finished (check log if errors)."
wait "$pid_lambda" || status=$(( status | 4 )); echo "[LAMBDA] finished (check log if errors)."

if [[ "$status" -ne 0 ]]; then
  echo "One or more failed (bitmask=$status). Tail of logs:" >&2
  for name in ec2 ecs lambda; do
    f="logs/${name}-$stamp.log"
    if [[ -f "$f" ]]; then
      echo "--- $f (last 15 lines) ---" >&2
      tail -n 15 "$f" >&2 || true
    fi
  done
  exit 1
fi

echo
echo "All parallel tests finished. Open Grafana: $GRAF"
