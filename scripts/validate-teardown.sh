#!/usr/bin/env bash
# Checks that a destroy actually removed everything billable, by asking AWS
# rather than Terraform. State can disagree with reality: a resource created
# outside the stack, one removed from state, or a destroy that failed halfway
# all leave charges running while `terraform state list` looks clean.
#
# Resources are matched by the project prefix, so anything else in the account
# is ignored.
#
#   ./scripts/validate-teardown.sh
#
# Exit code is 0 when nothing billable survives. The state backend (S3 bucket
# and DynamoDB lock table from terraform/bootstrap) is expected to survive and
# is reported separately - `make destroy` does not touch it by design.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source scripts/lib.sh

# lib.sh sets -e. Every check here must run even when an earlier one fails: a
# transient API error would otherwise abort the script partway, and the checks
# that never ran would read as passes.
set +e

VALIDATE_WARNED=0
VALIDATE_FAILED=0
VALIDATE_UNKNOWN=0

# Reports what a query returned: empty is the pass case. Counts rows, so every
# query below projects to [Field] form - a bare scalar list would come back as
# one tab-separated line and count as a single resource.
check() {
  local label="$1" count out rc
  shift
  out="$("$@" 2>/dev/null)"
  rc=$?
  # A failed query proves nothing either way, so it must not be reported as
  # "none" - that would turn an API outage into a clean bill of health.
  if [[ "$rc" -ne 0 ]]; then
    warn "$label: query failed (exit $rc) - status unknown, re-run"
    VALIDATE_UNKNOWN=$((VALIDATE_UNKNOWN + 1))
    return
  fi
  count="$(printf '%s' "$out" | grep -c '[^[:space:]]' || true)"
  if [[ "$count" -eq 0 ]]; then
    ok "$label: none"
  else
    fail "$label: $count still present"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

q() { aws "$@" --region "$REGION" --output text; }

section "compute"

check "EC2 instances" q ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-*" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]'

check "Auto Scaling groups" q autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,'${PROJECT}')].[AutoScalingGroupName,DesiredCapacity]"

check "ECS clusters" q ecs list-clusters \
  --query "clusterArns[?contains(@,'${PROJECT}')].[@]"

check "Lambda functions" q lambda list-functions \
  --query "Functions[?starts_with(FunctionName,'${PROJECT}')].[FunctionName]"

section "network and storage"

check "Load balancers" q elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName,'${PROJECT}')].[LoadBalancerName,State.Code]"

check "NAT gateways" q ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=${PROJECT}-*" \
  --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]'

check "Elastic IPs" q ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PROJECT}-*" \
  --query 'Addresses[].[AllocationId,PublicIp]'

check "RDS instances" q rds describe-db-instances \
  --query "DBInstances[?starts_with(DBInstanceIdentifier,'${PROJECT}')].[DBInstanceIdentifier,DBInstanceStatus]"

# Volumes outlive their instance when DeleteOnTermination was cleared, and are
# charged whether or not anything is attached to them.
check "EBS volumes" q ec2 describe-volumes \
  --filters "Name=tag:Name,Values=${PROJECT}-*" \
  --query 'Volumes[].[VolumeId,Size,State]'

section "stack resources charged at rest"

# ECR and Secrets Manager are part of the root stack, so a successful destroy
# removes them: ecr has force_delete, and the secrets module uses a recovery
# window of 0. Surviving means the destroy did not finish.
check "ECR repositories" q ecr describe-repositories \
  --query "repositories[?starts_with(repositoryName,'${PROJECT}')].[repositoryName]"

check "Secrets Manager secrets" q secretsmanager list-secrets \
  --query "SecretList[?starts_with(Name,'${PROJECT}')].[Name]"

# Snapshots are not created by a normal teardown - the RDS module sets
# skip_final_snapshot - so any that exist were made deliberately and are kept.
out="$(q rds describe-db-snapshots \
  --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'${PROJECT}')].[DBSnapshotIdentifier]" 2>/dev/null)"
if [[ -z "${out// /}" ]]; then
  ok "RDS snapshots: none"
else
  warn "RDS snapshots: kept, and charged for storage"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# The results bucket holds every run's Artillery output and is declared with
# force_destroy, so `make destroy` empties and deletes it without prompting -
# unreviewed measurements are gone. Run this before destroying, not only after.
results_bucket="$(aws s3api list-buckets --output text \
  --query "Buckets[?starts_with(Name,'${PROJECT}-loadgen')].Name" 2>/dev/null | tr '\t' '\n' | head -1)"
if [[ -n "$results_bucket" ]]; then
  objects="$(aws s3 ls "s3://$results_bucket/results/" --recursive 2>/dev/null | grep -c . || true)"
  warn "results bucket $results_bucket still holds $objects object(s)"
  printf '       destroy deletes these permanently (force_destroy). Download first:\n'
  printf '       aws s3 cp s3://%s/results/ ./results/ --recursive\n' "$results_bucket"
else
  ok "results bucket: gone (its contents went with it)"
fi

section "state backend (expected to survive)"

# Read the name from the backend config rather than guessing a prefix: the
# state bucket is not named after the project.
state_bucket="$(grep -oE 'bucket[[:space:]]*=[[:space:]]*"[^"]+"' terraform/backend.tf 2>/dev/null | head -1 | cut -d'"' -f2)"
if [[ -z "$state_bucket" ]]; then
  warn "could not read the state bucket name from terraform/backend.tf"
elif aws s3api head-bucket --bucket "$state_bucket" >/dev/null 2>&1; then
  ok "state bucket present: $state_bucket (make destroy does not remove it, by design)"
else
  warn "state bucket $state_bucket is gone - terraform/bootstrap was torn down too"
fi

section "summary"

if [[ "$VALIDATE_FAILED" -gt 0 ]]; then
  printf 'FAIL %s billable resource group(s) survived. Re-run make destroy, or remove them by hand.\n' "$VALIDATE_FAILED"
  exit 1
fi
if [[ "$VALIDATE_UNKNOWN" -gt 0 ]]; then
  printf 'FAIL %s check(s) could not run, so the teardown is unverified. Re-run.\n' "$VALIDATE_UNKNOWN"
  exit 1
fi
if [[ "$VALIDATE_WARNED" -gt 0 ]]; then
  printf 'OK   nothing billable is running. %s item(s) to review - see above.\n' "$VALIDATE_WARNED"
  exit 0
fi
ok "teardown complete: nothing left in $REGION under $PROJECT"
