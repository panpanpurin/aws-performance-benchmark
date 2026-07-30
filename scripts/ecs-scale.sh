#!/usr/bin/env bash
# Scale ECS services and ASG capacity.
#
#   ./scripts/ecs-scale.sh up      # services=1, ASG=3
#   ./scripts/ecs-scale.sh down    # services=0, ASG=0
#   ./scripts/ecs-scale.sh status
#   make ecs-up | make ecs-down | make ecs-status

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need aws

CLUSTER="${CLUSTER:-${PROJECT}-cluster}"
ASG="${ASG:-${PROJECT}-ecs-asg}"
SERVICES=(anilove csv-processor thumbnail-generator)
MODE="${1:-status}"

scale_services() {
  local n="$1"
  for s in "${SERVICES[@]}"; do
    echo "==> service $s desired=$n"
    aws ecs update-service \
      --region "$REGION" \
      --cluster "$CLUSTER" \
      --service "$s" \
      --desired-count "$n" \
      --query "service.{name:serviceName,desired:desiredCount,running:runningCount}" \
      --output table
  done
}

scale_asg() {
  local n="$1"
  echo "==> ASG $ASG desired=$n"
  aws autoscaling set-desired-capacity \
    --region "$REGION" \
    --auto-scaling-group-name "$ASG" \
    --desired-capacity "$n" \
    --honor-cooldown
}

show_status() {
  echo "=== ECS services ($CLUSTER) ==="
  aws ecs describe-services \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "${SERVICES[@]}" \
    --query "services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount,status:status}" \
    --output table
  echo
  echo "=== ASG ($ASG) ==="
  aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --auto-scaling-group-names "$ASG" \
    --query "AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,InService:length(Instances)}" \
    --output table
}

case "$MODE" in
  up)
    scale_asg 3
    scale_services 1
    echo "Wait 1-2 minutes for tasks to become RUNNING, then: make ecs-status"
    ;;
  down)
    scale_services 0
    scale_asg 0
    echo "ECS scaled to zero."
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {up|down|status}" >&2
    exit 1
    ;;
esac
