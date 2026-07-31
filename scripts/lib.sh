#!/usr/bin/env bash
# Shared helpers for repo scripts. Source only:  source "$(dirname "$0")/lib.sh"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-aws-perf-bench}"
TARGETS_FILE="${TARGETS_FILE:-$ROOT/terraform/generated/benchmark-targets.json}"

# Git Bash on Windows: find tools installed under Program Files
export PATH="/c/Program Files/nodejs:/c/Program Files/Amazon/AWSCLIV2:/c/Program Files/Docker/Docker/resources/bin:${APPDATA:-}/npm:$PATH"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found in PATH" >&2
    exit 127
  }
}

need_file() {
  [[ -f "$1" ]] || {
    echo "ERROR: missing file: $1" >&2
    exit 1
  }
}

# Read a top-level string field from benchmark-targets.json (requires python or jq)
json_get() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty' "$TARGETS_FILE"
    return
  fi
  local f="$TARGETS_FILE"
  if command -v cygpath >/dev/null 2>&1; then
    f="$(cygpath -m "$TARGETS_FILE")"
  fi
  node -e "
const t=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const v=t[process.argv[2]];
if (v!==undefined && v!==null && typeof v!=='object') process.stdout.write(String(v));
" "$f" "$key"
}

json_get_nested() {
  local path="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".$path // empty" "$TARGETS_FILE"
    return
  fi
  local f="$TARGETS_FILE"
  if command -v cygpath >/dev/null 2>&1; then
    f="$(cygpath -m "$TARGETS_FILE")"
  fi
  node -e "
const t=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const parts=process.argv[2].split('.');
let cur=t;
for (const p of parts) {
  if (cur==null || typeof cur!=='object' || !(p in cur)) process.exit(0);
  cur=cur[p];
}
if (cur!==undefined && cur!==null) {
  process.stdout.write(typeof cur==='object' ? JSON.stringify(cur) : String(cur));
}
" "$f" "$path"
}

require_targets() {
  need_file "$TARGETS_FILE"
}

# --- reporting for validate-*.sh -------------------------------------------
# Checks report through these instead of exiting, so one run surfaces every
# problem. End with: validate_summary "<name>"

VALIDATE_FAILED=0
VALIDATE_WARNED=0

section() { printf '\n=== %s ===\n' "$*"; }
ok()      { printf 'OK   %s\n' "$*"; }
skip()    { printf 'SKIP %s\n' "$*"; }
warn()    { printf 'WARN %s\n' "$*"; VALIDATE_WARNED=$((VALIDATE_WARNED + 1)); }
fail()    { printf 'FAIL %s\n' "$*"; VALIDATE_FAILED=$((VALIDATE_FAILED + 1)); }

validate_summary() {
  local name="${1:-validation}"
  printf '\n'
  if [[ "$VALIDATE_FAILED" -ne 0 ]]; then
    printf '%s: %d failed, %d warning(s).\n' "$name" "$VALIDATE_FAILED" "$VALIDATE_WARNED" >&2
    return 1
  fi
  printf '%s: passed, %d warning(s).\n' "$name" "$VALIDATE_WARNED"
  return 0
}

# --- app table and AWS discovery -------------------------------------------
# Mirrors terraform/locals.tf. Key is the terraform map key; name is the
# resource/service name; port is the container port.

APP_KEYS=(anilove csv thumbnail)

app_name() {
  case "$1" in
    anilove) echo anilove ;;
    csv) echo csv-processor ;;
    thumbnail) echo thumbnail-generator ;;
  esac
}

app_port() {
  case "$1" in
    anilove) echo 3000 ;;
    csv) echo 8000 ;;
    thumbnail) echo 3001 ;;
  esac
}

# Suite directory under benchmarks/suites/ for an app key.
app_suite() { app_name "$1"; }

# First `key = value` from terraform.tfvars, comments and quotes stripped.
tfvar() {
  local f="$ROOT/terraform/terraform.tfvars"
  [[ -f "$f" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$f" |
    head -n 1 |
    sed 's/[[:space:]]*#.*$//' |
    tr -d '"\r' |
    sed 's/[[:space:]]*$//'
}

# Let terraform.tfvars win over the defaults at the top of this file.
load_project_config() {
  local p r
  p="$(tfvar project_name)"
  r="$(tfvar aws_region)"
  [[ -n "$p" ]] && PROJECT="$p"
  [[ -n "$r" ]] && REGION="$r"
  return 0
}

# ALB DNS name: generated targets file first, then AWS.
discover_alb_dns() {
  local dns=""
  if [[ -f "$TARGETS_FILE" ]]; then
    dns="$(json_get alb_dns || true)"
  fi
  if [[ -z "$dns" ]]; then
    dns="$(aws elbv2 describe-load-balancers --region "$REGION" \
      --names "${PROJECT}-apps" \
      --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)"
  fi
  [[ "$dns" == "None" ]] && dns=""
  printf '%s' "$dns"
}

# Lambda Function URL for an app key.
discover_lambda_url() {
  local key="$1" url=""
  if [[ -f "$TARGETS_FILE" ]]; then
    url="$(json_get_nested "lambda_urls.$key" || true)"
  fi
  if [[ -z "$url" ]]; then
    url="$(aws lambda get-function-url-config --region "$REGION" \
      --function-name "${PROJECT}-$(app_name "$key")" \
      --query FunctionUrl --output text 2>/dev/null || true)"
  fi
  [[ "$url" == "None" ]] && url=""
  printf '%s' "${url%/}"
}

# ALB Host header for an app key on a platform (ec2|ecs), per locals.tf.
discover_host() {
  local key="$1" platform="$2" host=""
  if [[ -f "$TARGETS_FILE" ]]; then
    host="$(json_get_nested "hostnames.${key}_${platform}" || true)"
  fi
  if [[ -z "$host" ]]; then
    local suffix
    suffix="$(tfvar domain_name)"
    [[ -n "$suffix" ]] || suffix="bench.local"
    # thumbnail's ECS host is deliberately shortened in locals.tf
    if [[ "$key" == "thumbnail" && "$platform" == "ecs" ]]; then
      host="thumbnail-ecs.${suffix}"
    else
      host="$(app_name "$key")-${platform}.${suffix}"
    fi
  fi
  printf '%s' "$host"
}

export MSYS_NO_PATHCONV=1
