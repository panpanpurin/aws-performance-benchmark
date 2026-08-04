#!/usr/bin/env bash
# Stage the Artillery suites onto the in-region load generator, via S3.
#
#   bash scripts/loadgen-sync.sh            # all suites
#   bash scripts/loadgen-sync.sh csv-processor
#   make loadgen-sync
#
# Run after sync-artillery-targets.sh and after any edit to a test-*.yml,
# pilot-*.yml, processor or fixture. The generator runs what was last synced.
#
# S3 is the transport: the fixtures are too large for SSM parameters and the
# instance has no inbound port.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need aws

# Relative paths from here: $ROOT is an MSYS path (/c/Users/...) that neither
# node nor the Windows AWS CLI can resolve.
cd "$ROOT"

TARGETS="terraform/generated/benchmark-targets.json"
if [[ ! -f "$TARGETS" ]]; then
  echo "FAIL no $TARGETS - run terraform apply first" >&2
  exit 1
fi

# readFileSync, not require(): a path without a leading ./ is treated as a
# module name.
read -r INSTANCE BUCKET < <(node -e '
const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (!j.loadgen) { console.error("FAIL loadgen not in benchmark-targets.json - set enable_loadgen = true and apply"); process.exit(1); }
console.log(j.loadgen.instance_id, j.loadgen.bucket);
' "$TARGETS")

SUITES=("${1:-}")
if [[ -z "${SUITES[0]}" ]]; then
  SUITES=(anilove csv-processor thumbnail-generator)
fi

section "staging suites to s3://$BUCKET"

for suite in "${SUITES[@]}"; do
  src="benchmarks/suites/$suite/artillery"
  if [[ ! -d "$src" ]]; then
    fail "no such suite: $suite"
    continue
  fi
  # node_modules: form-data is installed globally on the instance via NODE_PATH.
  # logs: a local run must not overwrite results collected from the generator.
  aws s3 sync "$src" "s3://$BUCKET/suites/$suite/" \
    --exclude "node_modules/*" \
    --exclude "logs/*" \
    --delete \
    --only-show-errors
  ok "uploaded $suite"
done

section "pulling onto the generator"

cmd_id="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE" \
  --document-name "AWS-RunShellScript" \
  --comment "sync artillery suites" \
  --parameters commands="[\"set -eux\",\"mkdir -p /opt/bench/suites\",\"aws s3 sync s3://$BUCKET/suites/ /opt/bench/suites/ --delete --only-show-errors\",\"chown -R ec2-user:ec2-user /opt/bench\",\"ls -R /opt/bench/suites | head -40\"]" \
  --query 'Command.CommandId' --output text)"

echo "ssm command: $cmd_id"

# send-command returns immediately.
for _ in $(seq 1 60); do
  status="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Success) break ;;
    Failed|Cancelled|TimedOut)
      fail "ssm sync $status"
      aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cmd_id" --instance-id "$INSTANCE" \
        --query 'StandardErrorContent' --output text >&2
      exit 1
      ;;
  esac
  sleep 3
done

if [[ "$status" != "Success" ]]; then
  fail "ssm sync did not finish (last status: $status)"
  exit 1
fi

ok "generator has the current suites"
