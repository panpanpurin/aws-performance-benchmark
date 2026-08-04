#!/usr/bin/env bash
# Run a suite's three Artillery processes on the in-region load generator.
#
#   bash scripts/loadgen-run.sh csv-processor pilot
#   bash scripts/loadgen-run.sh csv-processor
#   make loadgen-pilot-csv | make loadgen-artillery-csv
#
# Prerequisite: scripts/loadgen-sync.sh - the generator runs what was last
# synced, not the working tree.
#
# The three platforms run concurrently so they share a time window. Logs and the
# Artillery JSON report come back to benchmarks/suites/<suite>/artillery/logs/.
# Client-side metrics come from the JSON report: the pushgateways listen on the
# workstation and the generator cannot reach them.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need aws

SUITE="${1:-}"
MODE="${2:-test}"
case "$SUITE" in
  anilove | csv-processor | thumbnail-generator) ;;
  *)
    echo "Usage: $0 <anilove|csv-processor|thumbnail-generator> [pilot]" >&2
    exit 1
    ;;
esac
case "$MODE" in
  test) PREFIX="test" ;;
  pilot) PREFIX="pilot" ;;
  *)
    echo "Unknown mode: $MODE (expected 'pilot' or nothing)" >&2
    exit 1
    ;;
esac

# Paths stay relative from here on. $ROOT is an MSYS path (/c/Users/...) under
# Git Bash, which neither node nor the Windows AWS CLI can resolve.
cd "$ROOT"

TARGETS="terraform/generated/benchmark-targets.json"
# fs.readFileSync, not require(): require() treats a path without a leading "./"
# as a module name and searches node_modules for it.
read -r INSTANCE BUCKET < <(node -e '
const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (!j.loadgen) { console.error("FAIL loadgen not provisioned - set enable_loadgen = true and apply"); process.exit(1); }
console.log(j.loadgen.instance_id, j.loadgen.bucket);
' "$TARGETS")

STAMP="$(date -u +%Y%m%d-%H%M%S)"
# Start time, used to scope the CloudWatch window below.
RUN_STARTED_AT="$(date -u +%s)"
REMOTE="/opt/bench/suites/$SUITE"
OUTDIR="benchmarks/suites/$SUITE/artillery/logs"
mkdir -p "$OUTDIR"

section "$SUITE ($MODE) on $INSTANCE"
echo "run id: $STAMP"

# NODE_PATH resolves form-data from the global install.
read -r -d '' SCRIPT <<EOF || true
set -eux
export NODE_PATH=\$(npm root -g)
cd $REMOTE
mkdir -p logs
node -v
artillery --version | head -1

declare -A pids
for p in ec2 ecs lambda; do
  artillery run "$PREFIX-\$p.yml" \
    --output "logs/loadgen-$PREFIX-\$p-$STAMP.json" \
    > "logs/loadgen-$PREFIX-\$p-$STAMP.log" 2>&1 &
  pids[\$p]=\$!
done

# Collect each exit code. `wait` alone returns only the last background job status,
# so a process that fails at startup would still report Success.
rc=0
for p in ec2 ecs lambda; do
  if ! wait "\${pids[\$p]}"; then
    echo "ARTILLERY_FAILED \$p"
    rc=1
  fi
done

aws s3 cp logs/ "s3://$BUCKET/results/$SUITE/" --recursive \
  --exclude "*" --include "*$STAMP*" --only-show-errors

if [ "\$rc" -ne 0 ]; then
  echo "ARTILLERY_RUN_FAILED $STAMP"
  exit 1
fi
echo "ARTILLERY_RUN_COMPLETE $STAMP"
EOF

cmd_id="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE" \
  --document-name "AWS-RunShellScript" \
  --comment "artillery $SUITE $MODE" \
  --timeout-seconds 3600 \
  --parameters "$(node -e '
const fs = require("fs");
const script = fs.readFileSync(0, "utf8");
console.log(JSON.stringify({ commands: [script], executionTimeout: ["7200"] }));
' <<<"$SCRIPT")" \
  --query 'Command.CommandId' --output text)"

echo "ssm command: $cmd_id"
if [[ "$PREFIX" == "pilot" ]]; then
  echo "Pilot takes about 7 minutes."
else
  echo "Full phases take 30+ minutes."
fi

# SSM has no live output for RunShellScript, so poll.
status="Pending"
for _ in $(seq 1 900); do
  status="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Success | Failed | Cancelled | TimedOut) break ;;
  esac
  sleep 10
done

echo "ssm status: $status"

# Collect partial results on failure too.
aws s3 cp "s3://$BUCKET/results/$SUITE/" "$OUTDIR/" --recursive \
  --exclude "*" --include "*$STAMP*" --only-show-errors 2>/dev/null || true

if [[ "$status" != "Success" ]]; then
  fail "run $status"
  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE" \
    --query 'StandardErrorContent' --output text 2>/dev/null | tail -30 >&2 || true
  exit 1
fi

ok "run complete"
echo "results in $OUTDIR (loadgen-$PREFIX-*-$STAMP.*)"
ls -1 "$OUTDIR" | grep "$STAMP" || echo "WARN nothing downloaded - check s3://$BUCKET/results/$SUITE/"

# The generator cannot reach the local pushgateways, so publish from here.
section "publishing client-side metrics"
node scripts/push-artillery-report.js "$SUITE" "$STAMP" || \
  warn "could not publish client-side metrics - is the $SUITE metrics stack up?"

# Lambda comes from CloudWatch: with more than one sandbox the app_* metrics are
# sampled from whichever one answers the scrape.
# Scoped to this run plus 120s for delivery lag. A fixed window would mix in
# earlier runs.
RUN_ELAPSED=$(( $(date -u +%s) - RUN_STARTED_AT + 120 ))
section "publishing lambda cloudwatch metrics (window ${RUN_ELAPSED}s)"
node scripts/push-lambda-cloudwatch.js "$SUITE" "$RUN_ELAPSED" || \
  warn "could not publish Lambda CloudWatch metrics"
