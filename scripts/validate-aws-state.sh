#!/usr/bin/env bash
# Post-apply check of deployed resource state.
#
# health-check.sh confirms the ALB returns 200 for one request per host. This
# script checks target group registration and health, ECS running counts, EC2
# status checks, Lambda state, and RDS availability. A single 200 response
# does not indicate that every target in a group is healthy, because the ALB
# routes each request to one target.
#
#   ./scripts/validate-aws-state.sh
#   make validate-aws
#
# Read-only: describe/list calls only.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need aws
load_project_config

EN_EC2="$(tfvar enable_ec2)"
EN_ECS="$(tfvar enable_ecs)"
EN_LAMBDA="$(tfvar enable_lambda)"
EN_RDS="$(tfvar enable_rds)"

echo "=== AWS state validation ==="

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "no AWS credentials (aws configure)"
  validate_summary "AWS state" || exit 1
fi
echo "project=$PROJECT region=$REGION"

# --- ALB -------------------------------------------------------------------
section "load balancer"
alb_json="$(aws elbv2 describe-load-balancers --region "$REGION" --names "${PROJECT}-apps" \
  --query 'LoadBalancers[0].[State.Code,DNSName]' --output text 2>/dev/null || true)"
if [[ -z "$alb_json" || "$alb_json" == "None"* ]]; then
  fail "ALB ${PROJECT}-apps not found - has the core stack been applied?"
  ALB_DNS=""
else
  read -r alb_state ALB_DNS <<<"$alb_json"
  if [[ "$alb_state" == "active" ]]; then
    ok "ALB ${PROJECT}-apps active ($ALB_DNS)"
  else
    fail "ALB ${PROJECT}-apps state=$alb_state"
  fi
  n_listeners="$(aws elbv2 describe-listeners --region "$REGION" \
    --load-balancer-arn "$(aws elbv2 describe-load-balancers --region "$REGION" \
      --names "${PROJECT}-apps" --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
    --query 'length(Listeners)' --output text 2>/dev/null || echo 0)"
  if [[ "$n_listeners" -lt 1 ]]; then
    fail "ALB has no listeners"
  else
    ok "$n_listeners listener(s)"
  fi
fi

# An ECS target group is legitimately empty while services sit at desired=0
# (the normal state after `make ecs-down`), so look the counts up first.
ecs_desired_for() {
  local app_name_want="$1"
  awk -v want="$app_name_want" '$1 == want { print $2 }' <<<"$ECS_DESIRED"
}
ECS_DESIRED=""
if [[ "$EN_ECS" == "true" ]]; then
  ECS_DESIRED="$(aws ecs describe-services --region "$REGION" --cluster "${PROJECT}-cluster" \
    --services anilove csv-processor thumbnail-generator \
    --query 'services[].[serviceName,desiredCount]' --output text 2>/dev/null || true)"
fi

# --- Target groups ---------------------------------------------------------
# Six groups: one per app per long-running platform. Lambda is reached through
# Function URLs rather than the ALB, so it has no target group.
section "target groups"
for key in "${APP_KEYS[@]}"; do
  for platform in ec2 ecs; do
    enabled="EN_${platform^^}"
    tg_name="${PROJECT}-${key}-${platform}"
    tg_name="${tg_name:0:32}"
    tg_arn="$(aws elbv2 describe-target-groups --region "$REGION" --names "$tg_name" \
      --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
    if [[ -z "$tg_arn" || "$tg_arn" == "None" ]]; then
      if [[ "${!enabled}" == "true" ]]; then
        fail "target group $tg_name missing but enable_$platform=true"
      else
        skip "$tg_name (enable_$platform is false)"
      fi
      continue
    fi

    health="$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$tg_arn" \
      --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>/dev/null || true)"
    if [[ -z "$health" ]]; then
      if [[ "${!enabled}" != "true" ]]; then
        skip "$tg_name empty (enable_$platform is false)"
      elif [[ "$platform" == "ecs" && "$(ecs_desired_for "$(app_name "$key")")" == "0" ]]; then
        warn "$tg_name empty - service scaled to 0 (make ecs-up before a run)"
      else
        fail "$tg_name has no registered targets - $key/$platform serves nothing"
      fi
      continue
    fi
    total="$(echo "$health" | tr '\t' '\n' | grep -c . || true)"
    healthy="$(echo "$health" | tr '\t' '\n' | grep -c '^healthy$' || true)"
    if [[ "$healthy" -eq "$total" ]]; then
      ok "$tg_name $healthy/$total healthy"
    else
      fail "$tg_name only $healthy/$total healthy ($(echo "$health" | tr '\t' ' '))"
    fi
  done
done

# --- EC2 -------------------------------------------------------------------
section "EC2"
if [[ "$EN_EC2" != "true" ]]; then
  skip "enable_ec2 is false"
else
  found=0
  while read -r iid app state sys inst; do
    [[ -n "$iid" ]] || continue
    found=$((found + 1))
    if [[ "$state" == "running" && "$sys" == "ok" && "$inst" == "ok" ]]; then
      ok "$app $iid running, status checks 2/2"
    else
      fail "$app $iid state=$state system=$sys instance=$inst"
    fi
  done < <(
    aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Platform,Values=ec2" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`App`]|[0].Value,State.Name]' \
      --output text 2>/dev/null | tr -d '\r' |
      while read -r iid app state; do
        [[ -n "$iid" ]] || continue
        st="$(aws ec2 describe-instance-status --region "$REGION" --instance-ids "$iid" \
          --query 'InstanceStatuses[0].[SystemStatus.Status,InstanceStatus.Status]' \
          --output text 2>/dev/null || echo "unknown unknown")"
        echo "$iid $app $state $st"
      done
  )
  [[ "$found" -eq 0 ]] && fail "no EC2 app instances tagged Platform=ec2 but enable_ec2=true"
fi

# --- ECS -------------------------------------------------------------------
section "ECS"
if [[ "$EN_ECS" != "true" ]]; then
  skip "enable_ecs is false"
else
  cluster="${PROJECT}-cluster"
  cstate="$(aws ecs describe-clusters --region "$REGION" --clusters "$cluster" \
    --query 'clusters[0].[status,registeredContainerInstancesCount]' --output text 2>/dev/null || true)"
  if [[ -z "$cstate" || "$cstate" == "None"* ]]; then
    fail "ECS cluster $cluster not found"
  else
    read -r cstatus cinstances <<<"$cstate"
    if [[ "$cstatus" != "ACTIVE" ]]; then
      fail "cluster $cluster status=$cstatus"
    elif [[ "$cinstances" -lt 1 ]]; then
      fail "cluster $cluster has 0 container instances - run: make ecs-up"
    else
      ok "cluster $cluster ACTIVE, $cinstances container instance(s)"
    fi

    while read -r name desired running pending rollout; do
      [[ -n "$name" ]] || continue
      if [[ "$desired" -eq 0 ]]; then
        warn "service $name desired=0 - scaled down (make ecs-up before a run)"
      elif [[ "$running" -ne "$desired" ]]; then
        fail "service $name running=$running desired=$desired pending=$pending"
      elif [[ "$rollout" == "FAILED" ]]; then
        fail "service $name last deployment rollout FAILED"
      else
        ok "service $name $running/$desired running"
      fi
    done < <(aws ecs describe-services --region "$REGION" --cluster "$cluster" \
      --services anilove csv-processor thumbnail-generator \
      --query 'services[].[serviceName,desiredCount,runningCount,pendingCount,deployments[0].rolloutState]' \
      --output text 2>/dev/null | tr -d '\r' || true)
  fi

  asg="${PROJECT}-ecs-asg"
  asg_state="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$asg" \
    --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances[?LifecycleState==`InService`])]' \
    --output text 2>/dev/null || true)"
  if [[ -n "$asg_state" && "$asg_state" != "None"* ]]; then
    read -r asg_desired asg_inservice <<<"$asg_state"
    if [[ "$asg_inservice" -lt "$asg_desired" ]]; then
      fail "ASG $asg has $asg_inservice/$asg_desired instances InService"
    else
      ok "ASG $asg $asg_inservice/$asg_desired InService"
    fi
  fi
fi

# --- Lambda ----------------------------------------------------------------
section "Lambda"
if [[ "$EN_LAMBDA" != "true" ]]; then
  skip "enable_lambda is false"
else
  for key in "${APP_KEYS[@]}"; do
    fn="${PROJECT}-$(app_name "$key")"
    cfg="$(aws lambda get-function-configuration --region "$REGION" --function-name "$fn" \
      --query '[State,LastUpdateStatus,PackageType]' --output text 2>/dev/null || true)"
    if [[ -z "$cfg" ]]; then
      fail "lambda $fn not found but enable_lambda=true"
      continue
    fi
    read -r lstate lupdate lpkg <<<"$cfg"
    if [[ "$lstate" != "Active" ]]; then
      fail "lambda $fn State=$lstate"
    elif [[ "$lupdate" != "Successful" ]]; then
      fail "lambda $fn LastUpdateStatus=$lupdate"
    else
      ok "lambda $fn Active ($lpkg)"
    fi
    if ! aws lambda get-function-url-config --region "$REGION" --function-name "$fn" \
      --query FunctionUrl --output text >/dev/null 2>&1; then
      fail "lambda $fn has no Function URL - Artillery cannot reach it"
    fi
  done
fi

# --- RDS -------------------------------------------------------------------
section "RDS"
if [[ "$EN_RDS" != "true" ]]; then
  skip "enable_rds is false"
else
  db="${PROJECT}-anilove"
  dbs="$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$db" \
    --query 'DBInstances[0].[DBInstanceStatus,DBInstanceClass,Engine,EngineVersion]' \
    --output text 2>/dev/null || true)"
  if [[ -z "$dbs" ]]; then
    fail "RDS instance $db not found"
  else
    read -r dstatus dclass dengine dversion <<<"$dbs"
    if [[ "$dstatus" == "available" ]]; then
      ok "RDS $db available ($dclass, $dengine $dversion)"
    else
      fail "RDS $db status=$dstatus"
    fi
    # AniLove on all three platforms shares this one instance.
    want_class="$(tfvar rds_instance_class)"
    if [[ -n "$want_class" && "$dclass" != "$want_class" ]]; then
      warn "RDS class is $dclass but tfvars says $want_class - apply pending?"
    fi
  fi
fi

# --- Log groups ------------------------------------------------------------
section "log groups"
n_groups="$(aws logs describe-log-groups --region "$REGION" \
  --query "length(logGroups[?contains(logGroupName, '$PROJECT') || starts_with(logGroupName, '/ec2/') || starts_with(logGroupName, '/ecs/')])" \
  --output text 2>/dev/null || echo 0)"
if [[ "$n_groups" -gt 0 ]]; then
  ok "$n_groups log group(s) present"
else
  warn "no log groups matched - CloudWatch logs may be missing"
fi

echo
if [[ -n "$ALB_DNS" ]]; then
  echo "ALB: $(discover_scheme)://$ALB_DNS   (per-app /health: make health)"
fi

validate_summary "AWS state"
