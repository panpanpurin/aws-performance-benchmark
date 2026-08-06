#!/usr/bin/env bash
# Truncate and reseed the anilove schemas on RDS. Run before every repetition:
# the seeded rows are the page GET /animes reads, and leftovers make repetitions
# non-independent.
#
# RDS is not publicly accessible and its security group admits only the EC2, ECS
# and Lambda groups, so there is no path from a workstation. This goes through
# SSM to the anilove EC2 instance and runs the scripts inside the container,
# which holds the credentials. DB_SCHEMA is an env var, so one container reaches
# all three schemas.
#
#   ./scripts/db-reset.sh                 # clean + seed ec2, ecs, lambda
#   ./scripts/db-reset.sh --schemas ec2   # one schema
#   ./scripts/db-reset.sh --count         # rows per schema, changes nothing
#
# --count before a reset gives the cycles that died between create and delete,
# which the Artillery report does not show.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCHEMAS="ec2 ecs lambda"
COUNT_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schemas)
      [[ $# -ge 2 ]] || { echo "--schemas needs a value" >&2; exit 1; }
      SCHEMAS="${2//,/ }"
      shift 2
      ;;
    --count)
      COUNT_ONLY=1
      shift
      ;;
    *)
      echo "Usage: $0 [--schemas ec2,ecs,lambda] [--count]" >&2
      exit 1
      ;;
  esac
done

need aws
load_project_config

APP="$(app_name anilove)"

section "target instance"

# Tagged by the ec2_apps module: App is the application key, Name is derived.
INSTANCE="$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:App,Values=anilove" \
            "Name=tag:Project,Values=$PROJECT" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId | [0]' \
  --output text 2>/dev/null || echo "None")"

if [[ -z "$INSTANCE" || "$INSTANCE" == "None" ]]; then
  fail "no running anilove EC2 instance found in $REGION for project $PROJECT"
  echo "The instance is the only host with both the scripts and a route to RDS."
  echo "Bring it up with enable_ec2 = true and terraform apply."
  exit 1
fi
ok "instance $INSTANCE"

# Fails loudly rather than reporting success against a container that is not
# there: SSM returns Success for a shell that ran and printed an error.
build_script() {
  local schema="$1"
  if [[ "$COUNT_ONLY" == "1" ]]; then
    cat <<EOF
set -e
docker inspect -f '{{.State.Running}}' $APP >/dev/null 2>&1 || { echo "container $APP not running"; exit 1; }
docker exec -e DB_SCHEMA=$schema $APP node -e "
const s=require('/app/src/config/database');
const A=require('/app/src/models/Anime');
(async()=>{ try { console.log('$schema rows=' + await A.count()); process.exit(0); } catch(e){ console.error(e.message); process.exit(1); } })();
"
EOF
  else
    cat <<EOF
set -e
docker inspect -f '{{.State.Running}}' $APP >/dev/null 2>&1 || { echo "container $APP not running"; exit 1; }
docker exec -e DB_SCHEMA=$schema $APP node cleanDB.js
docker exec -e DB_SCHEMA=$schema $APP node seedDB.js
EOF
  fi
}

run_remote() {
  local schema="$1" script cmd_id status
  script="$(build_script "$schema")"

  cmd_id="$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE" \
    --document-name "AWS-RunShellScript" \
    --comment "db-reset $schema" \
    --timeout-seconds 600 \
    --parameters "$(node -e '
const fs = require("fs");
console.log(JSON.stringify({ commands: [fs.readFileSync(0, "utf8")], executionTimeout: ["600"] }));
' <<<"$script")" \
    --query 'Command.CommandId' --output text)"

  # SSM gives no live output for RunShellScript, so poll.
  status="Pending"
  for _ in $(seq 1 60); do
    status="$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$INSTANCE" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success | Failed | Cancelled | TimedOut) break ;;
    esac
    sleep 5
  done

  local out err
  out="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE" \
    --query 'StandardOutputContent' --output text 2>/dev/null || echo "")"
  err="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE" \
    --query 'StandardErrorContent' --output text 2>/dev/null || echo "")"

  [[ -n "$out" ]] && echo "$out" | sed 's/^/     /'
  if [[ "$status" != "Success" ]]; then
    [[ -n "$err" ]] && echo "$err" | sed 's/^/     /'
    fail "schema $schema: $status"
    return 1
  fi
  ok "schema $schema"
  return 0
}

if [[ "$COUNT_ONLY" == "1" ]]; then
  section "row count (no change)"
else
  section "truncate and reseed"
fi

rc=0
for schema in $SCHEMAS; do
  run_remote "$schema" || rc=1
done

# Not bare, or set -e exits here on failure and skips the explicit code below.
validate_summary "db-reset" || rc=1
exit "$rc"
