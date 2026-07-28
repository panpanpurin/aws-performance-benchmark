#!/usr/bin/env bash
# Shared parallel Artillery runner for EC2 + ECS + Lambda.
# Usage: run-parallel.sh <anilove|csv-processor|thumbnail-generator>
# Prerequisite: metrics stack up for that suite (make bench-<suite>).
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

cd "$ART_DIR"
command -v npx >/dev/null 2>&1 || { echo "npx not found" >&2; exit 127; }
for f in test-ec2.yml test-ecs.yml test-lambda.yml; do
  [ -f "$f" ] || { echo "Missing: $f" >&2; exit 1; }
done

mkdir -p logs
stamp=$(date +%Y%m%d-%H%M%S)
trap 'echo; echo "Stopping..."; pkill -P $$ || true; wait || true; exit 130' INT

echo "========================================"
echo " $TITLE - parallel EC2 / ECS / Lambda"
echo " Prerequisite: make $MAKE_HINT"
echo " Prometheus: $PROM"
echo " Grafana:    $GRAF"
echo " Pushgateway ECS/EC2/Lambda: $PG"
echo "========================================"

npx --yes artillery@2.0.23 run test-ec2.yml    > "logs/ec2-$stamp.log"    2>&1 & pid_ec2=$!
echo "[EC2] pid=$pid_ec2 -> logs/ec2-$stamp.log"
npx --yes artillery@2.0.23 run test-ecs.yml    > "logs/ecs-$stamp.log"    2>&1 & pid_ecs=$!
echo "[ECS] pid=$pid_ecs -> logs/ecs-$stamp.log"
npx --yes artillery@2.0.23 run test-lambda.yml > "logs/lambda-$stamp.log" 2>&1 & pid_lambda=$!
echo "[LAMBDA] pid=$pid_lambda -> logs/lambda-$stamp.log"

status=0
wait "$pid_ec2"    || status=$(( status | 1 )); echo "[EC2] finished."
wait "$pid_ecs"    || status=$(( status | 2 )); echo "[ECS] finished."
wait "$pid_lambda" || status=$(( status | 4 )); echo "[LAMBDA] finished."

if [ "$status" -ne 0 ]; then
  echo "One or more failed (bitmask=$status). See logs/." >&2
  exit 1
fi
echo "All parallel tests finished successfully."
