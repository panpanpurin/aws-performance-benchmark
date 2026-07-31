#!/usr/bin/env bash
# Validate the Terraform stack before an apply.
#
# Local checks always run (fmt, validate, backend wiring, tfvars sanity).
# AWS checks run when credentials resolve and enforce the documented apply
# order: bootstrap -> core stack -> push images -> flip enable_* -> apply.
#
#   ./scripts/validate-terraform.sh
#   ./scripts/validate-terraform.sh --offline
#   make validate-tf

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1

TF_DIR="$ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

# terraform.exe is a native Windows binary and cannot read MSYS /c/... paths.
winpath() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# First `key = value` assignment, comments and quotes stripped.
hcl_value() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" |
    head -n 1 |
    sed 's/[[:space:]]*#.*$//' |
    tr -d '"\r' |
    sed 's/[[:space:]]*$//'
}

# Same, but only inside the terraform { backend "s3" { ... } } block.
backend_value() {
  awk -v key="$2" '
    /backend[[:space:]]*"s3"[[:space:]]*{/ { inb = 1; next }
    inb && /^[[:space:]]*}/ { inb = 0 }
    inb {
      line = $0
      sub(/#.*$/, "", line)
      if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/["\r[:space:]]/, "", line)
        print line
        exit
      }
    }
  ' "$1"
}

echo "=== Terraform validation ==="

# --- Tooling ---------------------------------------------------------------
section "tooling"
if ! command -v terraform >/dev/null 2>&1; then
  fail "terraform not on PATH"
  validate_summary "Terraform" || exit 1
fi
tf_ver="$(terraform version -json 2>/dev/null |
  sed -n 's/.*"terraform_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[[ -n "$tf_ver" ]] || tf_ver="$(terraform version | head -n 1 | tr -d 'Terraform v')"
tf_maj="${tf_ver%%.*}"
tf_rest="${tf_ver#*.}"
tf_min="${tf_rest%%.*}"
if [[ "$tf_maj" =~ ^[0-9]+$ ]] && [[ "$tf_min" =~ ^[0-9]+$ ]] &&
  { ((tf_maj > 1)) || { ((tf_maj == 1)) && ((tf_min >= 5)); }; }; then
  ok "terraform $tf_ver (required >= 1.5)"
else
  fail "terraform $tf_ver is below the required 1.5"
fi

# --- Formatting ------------------------------------------------------------
section "fmt"
fmt_rc=0
fmt_out="$(terraform -chdir="$(winpath "$TF_DIR")" fmt -check -recursive 2>&1)" || fmt_rc=$?
if [[ "$fmt_rc" -eq 0 ]]; then
  ok "all files formatted"
elif [[ "$fmt_out" == *Error* ]]; then
  fail "terraform fmt errored"
  echo "$fmt_out" | tail -n 5
else
  while read -r f; do
    [[ -n "$f" ]] && fail "not formatted: terraform/$f (run: terraform -chdir=terraform fmt -recursive)"
  done <<<"$fmt_out"
fi

# --- Backend wiring --------------------------------------------------------
# Without a backend block, the core stack keeps state on the local filesystem.
section "state backend"
backend_file="$(grep -rl 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null | head -n 1 || true)"
STATE_BUCKET=""
LOCK_TABLE=""
BACKEND_REGION=""
if [[ -z "$backend_file" ]]; then
  fail "no backend \"s3\" block in terraform/*.tf - state would be local"
  echo "       fix: cp terraform/backend.tf.example terraform/backend.tf and fill it in"
  echo "       (apply terraform/bootstrap first if the bucket does not exist yet)"
else
  STATE_BUCKET="$(backend_value "$backend_file" bucket)"
  LOCK_TABLE="$(backend_value "$backend_file" dynamodb_table)"
  BACKEND_REGION="$(backend_value "$backend_file" region)"
  backend_key="$(backend_value "$backend_file" key)"
  backend_enc="$(backend_value "$backend_file" encrypt)"

  ok "backend in terraform/$(basename "$backend_file") -> s3://$STATE_BUCKET/$backend_key"
  [[ -n "$STATE_BUCKET" ]] || fail "backend has no bucket"
  [[ -n "$LOCK_TABLE" ]] || fail "backend has no dynamodb_table - concurrent applies would not lock"
  [[ "$backend_enc" == "true" ]] || warn "backend encrypt is not true"
fi

# backend.tf holds a bucket name containing an AWS account id and must stay out
# of version control. backend.tf.example is the tracked template.
if [[ -f "$TF_DIR/backend.tf" ]] && git -C "$ROOT" ls-files --error-unmatch terraform/backend.tf >/dev/null 2>&1; then
  fail "terraform/backend.tf is tracked by git - it exposes the state bucket and account id"
  echo "       fix: git rm --cached terraform/backend.tf"
fi
if [[ ! -f "$TF_DIR/backend.tf.example" ]]; then
  warn "terraform/backend.tf.example missing - nothing documents the backend for a fresh clone"
fi

# --- terraform validate ----------------------------------------------------
section "terraform validate"
for dir in "$TF_DIR" "$TF_DIR/bootstrap"; do
  [[ -d "$dir" ]] || continue
  rel="${dir#"$ROOT"/}"
  chdir="$(winpath "$dir")"
  # -backend=false keeps this from touching remote state or needing credentials.
  if ! init_out="$(terraform -chdir="$chdir" init -backend=false -input=false -no-color 2>&1)"; then
    fail "$rel: init -backend=false failed"
    echo "$init_out" | tail -n 5
    continue
  fi
  if val_out="$(terraform -chdir="$chdir" validate -no-color 2>&1)"; then
    ok "$rel valid"
  else
    fail "$rel: terraform validate failed"
    echo "$val_out" | tail -n 20
  fi
done

# --- tfvars ----------------------------------------------------------------
section "terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  fail "terraform/terraform.tfvars missing (copy terraform.tfvars.example)"
  validate_summary "Terraform" || exit 1
fi
ok "terraform.tfvars present"

# Keys that no variable declares - terraform errors on these at plan time.
while read -r key; do
  [[ -n "$key" ]] || continue
  if ! grep -q "^variable[[:space:]]*\"$key\"" "$TF_DIR/variables.tf"; then
    fail "tfvars sets '$key' but no such variable is declared"
  fi
done < <(sed -n 's/^\([a-z_][a-z0-9_]*\)[[:space:]]*=.*/\1/p' "$TFVARS")

# Unresolved placeholders.
while IFS= read -r line; do
  [[ -n "$line" ]] && fail "tfvars placeholder not filled: $line"
done < <(grep -nE '^[a-z_]+[[:space:]]*=.*(REPLACE|CHANGEME|TODO|sha256:\.\.\.|example\.com)' "$TFVARS" || true)

AWS_REGION_TFVARS="$(hcl_value "$TFVARS" aws_region)"
PROJECT_NAME="$(hcl_value "$TFVARS" project_name)"
DOMAIN="$(hcl_value "$TFVARS" domain_name)"
ZONE="$(hcl_value "$TFVARS" route53_zone_id)"
IMAGE_TAG="$(hcl_value "$TFVARS" ecr_image_tag)"
LAMBDA_TAG="$(hcl_value "$TFVARS" ecr_lambda_image_tag)"
EN_EC2="$(hcl_value "$TFVARS" enable_ec2)"
EN_ECS="$(hcl_value "$TFVARS" enable_ecs)"
EN_LAMBDA="$(hcl_value "$TFVARS" enable_lambda)"
LAMBDA_MEM="$(hcl_value "$TFVARS" lambda_memory_mb)"
ECS_MEM="$(hcl_value "$TFVARS" ecs_task_memory)"

: "${IMAGE_TAG:=latest}"
: "${LAMBDA_TAG:=lambda}"
: "${PROJECT_NAME:=$PROJECT}"

# ACM and Route 53 need both variables or neither. Setting only one produces an
# HTTP-only ALB without reporting an error.
if [[ -n "$DOMAIN" && -z "$ZONE" ]]; then
  fail "domain_name set but route53_zone_id empty - ACM validation cannot complete"
elif [[ -z "$DOMAIN" && -n "$ZONE" ]]; then
  fail "route53_zone_id set but domain_name empty"
elif [[ -z "$DOMAIN" ]]; then
  ok "HTTP-only ALB (no domain configured)"
else
  ok "HTTPS via $DOMAIN"
fi

if [[ -n "$BACKEND_REGION" && -n "$AWS_REGION_TFVARS" && "$BACKEND_REGION" != "$AWS_REGION_TFVARS" ]]; then
  warn "backend region ($BACKEND_REGION) differs from aws_region ($AWS_REGION_TFVARS)"
fi

# Lambda couples CPU to memory: it allocates one full vCPU at 1769 MB. The
# platforms are matched on CPU rather than memory, so compare vCPU budgets.
# ECS: cpu units / 1024. EC2 container is capped at the same value.
ECS_CPU="$(hcl_value "$TFVARS" ecs_task_cpu)"
if [[ -n "$LAMBDA_MEM" && -n "$ECS_CPU" ]]; then
  cpu_delta="$(node -e "
    const lam = Number(process.argv[1]) / 1769;
    const ecs = Number(process.argv[2]) / 1024;
    process.stdout.write(JSON.stringify({
      lam: lam.toFixed(2), ecs: ecs.toFixed(2),
      off: Math.abs(lam - ecs) > 0.1
    }));" "$LAMBDA_MEM" "$ECS_CPU" 2>/dev/null || echo '{}')"
  case "$cpu_delta" in
    *'"off":true'*)
      lam_v="$(sed -n 's/.*"lam":"\([^"]*\)".*/\1/p' <<<"$cpu_delta")"
      ecs_v="$(sed -n 's/.*"ecs":"\([^"]*\)".*/\1/p' <<<"$cpu_delta")"
      warn "vCPU budgets differ: lambda ${lam_v} (${LAMBDA_MEM} MB / 1769) vs ecs/ec2 ${ecs_v} (${ECS_CPU} / 1024)"
      ;;
    *'"off":false'*)
      ok "vCPU budget matched across platforms (lambda_memory_mb=$LAMBDA_MEM, ecs_task_cpu=$ECS_CPU)"
      ;;
  esac
fi

# Burstable families default to opposite credit modes (t2 standard,
# t3/t4g unlimited), which would let one platform burst while the other throttles.
EC2_TYPE="$(hcl_value "$TFVARS" ec2_instance_type)"
ECS_TYPE="$(hcl_value "$TFVARS" ecs_instance_type)"
CPU_CREDITS="$(hcl_value "$TFVARS" cpu_credits)"
if [[ "$EC2_TYPE" =~ ^t[234] || "$ECS_TYPE" =~ ^t[234] ]]; then
  if [[ -z "$CPU_CREDITS" ]]; then
    fail "burstable instance types in use ($EC2_TYPE / $ECS_TYPE) but cpu_credits is unset - t2 defaults to standard and t3 to unlimited"
  else
    warn "burstable types in use ($EC2_TYPE / $ECS_TYPE) with cpu_credits=$CPU_CREDITS - credit depletion makes repeated runs non-independent"
  fi
else
  ok "non-burstable instance types ($EC2_TYPE / $ECS_TYPE) - no CPU credit effects"
fi

echo "     project=$PROJECT_NAME region=${AWS_REGION_TFVARS:-?} enable ec2=$EN_EC2 ecs=$EN_ECS lambda=$EN_LAMBDA"

# --- AWS-side checks -------------------------------------------------------
section "AWS resources"
REGION="${AWS_REGION_TFVARS:-$REGION}"

if [[ "$OFFLINE" -eq 1 ]]; then
  skip "--offline"
elif ! command -v aws >/dev/null 2>&1; then
  skip "aws CLI not on PATH"
elif ! aws sts get-caller-identity >/dev/null 2>&1; then
  warn "no AWS credentials - skipped backend, ECR and image checks"
else
  account="$(aws sts get-caller-identity --query Account --output text)"
  ok "identity $account in $REGION"

  # State backend must already exist; the core stack cannot init without it.
  if [[ -n "$STATE_BUCKET" ]]; then
    if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
      ver="$(aws s3api get-bucket-versioning --bucket "$STATE_BUCKET" --query Status --output text 2>/dev/null || echo None)"
      if [[ "$ver" == "Enabled" ]]; then
        ok "state bucket $STATE_BUCKET (versioning on)"
      else
        warn "state bucket $STATE_BUCKET has versioning=$ver - no state history"
      fi
    else
      fail "state bucket $STATE_BUCKET not found - apply terraform/bootstrap first"
    fi
  fi
  if [[ -n "$LOCK_TABLE" ]]; then
    if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
      ok "lock table $LOCK_TABLE"
    else
      fail "lock table $LOCK_TABLE not found in $REGION - apply terraform/bootstrap first"
    fi
  fi

  # enable_* may only be true once the matching image is in ECR.
  check_image() {
    local repo="$1" tag="$2" why="$3" is_lambda="$4"
    if ! aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1; then
      fail "ECR repo $repo missing but $why - apply the core stack first"
      return
    fi
    if ! aws ecr describe-images --repository-name "$repo" --region "$REGION" \
      --image-ids "imageTag=$tag" >/dev/null 2>&1; then
      fail "$repo:$tag not pushed but $why - run: make push-images"
      return
    fi
    if [[ "$is_lambda" == "1" ]]; then
      local media
      media="$(aws ecr batch-get-image --region "$REGION" --repository-name "$repo" \
        --image-ids "imageTag=$tag" --query 'images[0].imageManifestMediaType' --output text 2>/dev/null || echo unknown)"
      if [[ "$media" == *index* ]]; then
        fail "$repo:$tag is an OCI image index - Lambda rejects it; rebuild with DOCKER_BUILDKIT=0"
        return
      fi
    fi
    ok "$repo:$tag present"
  }

  repos=("$PROJECT_NAME/anilove" "$PROJECT_NAME/csv-processor" "$PROJECT_NAME/thumbnail-generator")

  if [[ "$EN_EC2" == "true" || "$EN_ECS" == "true" ]]; then
    which=""
    [[ "$EN_EC2" == "true" ]] && which="enable_ec2=true"
    [[ "$EN_ECS" == "true" ]] && which="${which:+$which, }enable_ecs=true"
    for r in "${repos[@]}"; do check_image "$r" "$IMAGE_TAG" "$which" 0; done
  else
    skip "enable_ec2/enable_ecs are false - :$IMAGE_TAG images not required yet"
  fi

  if [[ "$EN_LAMBDA" == "true" ]]; then
    for r in "${repos[@]}"; do check_image "$r" "$LAMBDA_TAG" "enable_lambda=true" 1; done
  else
    skip "enable_lambda is false - :$LAMBDA_TAG images not required yet"
  fi
fi

validate_summary "Terraform"
