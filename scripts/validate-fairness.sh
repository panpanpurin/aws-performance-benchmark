#!/usr/bin/env bash
# Checks the benchmark's controlled-variable assumption: across the three
# platforms, only the compute model differs.
#
# A renamed metric, a removed thread pin, or a platform running an outdated
# image changes the results without causing a run to fail, so each condition
# is checked explicitly.
#
# Static checks always run. Deployed checks need AWS credentials; the /metrics
# scrape additionally needs the apps to be up (make ecs-up, make health).
#
#   ./scripts/validate-fairness.sh
#   ./scripts/validate-fairness.sh --offline    # source checks only
#   ./scripts/validate-fairness.sh --no-scrape  # skip live /metrics
#   make validate-fairness

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

OFFLINE=0
SCRAPE=1
for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=1 ;;
    --no-scrape) SCRAPE=0 ;;
    *)
      echo "Usage: $0 [--offline] [--no-scrape]" >&2
      exit 1
      ;;
  esac
done

load_project_config

# The contract in CLAUDE.md: identical names across all apps and platforms so
# one dashboard can split series by the `instance` label.
SHARED_METRICS=(
  app_total_execution_time_seconds
  app_internal_processing_time_seconds
  app_cold_start_duration_seconds
  app_cpu_usage_percent
  app_cpu_peak_percent
  app_ram_usage_mb
  app_ram_peak_mb
)

metrics_source() {
  case "$1" in
    anilove) echo "apps/anilove/src/metrics.js" ;;
    csv) echo "apps/csv-processor/app/metrics.py" ;;
    thumbnail) echo "apps/thumbnail-generator/src/metrics.js" ;;
  esac
}

echo "=== Benchmark fairness validation ==="
echo "project=$PROJECT region=$REGION"

# --- Metric name contract --------------------------------------------------
section "metric names (source)"
for key in "${APP_KEYS[@]}"; do
  src="$ROOT/$(metrics_source "$key")"
  if [[ ! -f "$src" ]]; then
    fail "$(metrics_source "$key") not found"
    continue
  fi
  missing=""
  for m in "${SHARED_METRICS[@]}"; do
    grep -q "$m" "$src" || missing="$missing $m"
  done
  if [[ -n "$missing" ]]; then
    fail "$key is missing shared metric(s):$missing - breaks the shared dashboards"
  else
    ok "$key declares all ${#SHARED_METRICS[@]} shared metrics"
  fi

  # An app_* name only one app defines cannot be compared across platforms.
  while read -r extra; do
    [[ -n "$extra" ]] || continue
    case " ${SHARED_METRICS[*]} " in
      *" $extra "*) ;;
      *) warn "$key defines '$extra', which the other apps do not - not comparable" ;;
    esac
  done < <(grep -o 'app_[a-z_]*' "$src" | sort -u)
done

# --- Grafana dashboards must reference metrics that exist ------------------
section "grafana dashboards"
for key in "${APP_KEYS[@]}"; do
  dash="$ROOT/benchmarks/suites/$(app_suite "$key")/grafana/dashboard.json"
  src="$ROOT/$(metrics_source "$key")"
  [[ -f "$dash" && -f "$src" ]] || continue
  dangling=""
  while read -r m; do
    [[ -n "$m" ]] || continue
    case "$m" in app_*) ;; *) continue ;; esac
    # _bucket/_count/_sum are emitted by Prometheus for histograms; the source
    # only declares the base name.
    base="${m%_bucket}"
    base="${base%_count}"
    base="${base%_sum}"
    grep -q "$base" "$src" || dangling="$dangling $m"
  done < <(grep -o 'app_[a-z_]*' "$dash" | sort -u)
  if [[ -n "$dangling" ]]; then
    fail "$(app_suite "$key")/grafana/dashboard.json queries undefined metric(s):$dangling"
  else
    ok "$(app_suite "$key") dashboard references only defined metrics"
  fi
done

# --- Fairness pins ---------------------------------------------------------
# Both settings approximate a 1-vCPU profile. Without them, a platform with
# more available cores produces different results for the same workload.
section "1-vCPU pins"
for df in apps/csv-processor/Dockerfile apps/csv-processor/Dockerfile.lambda; do
  if [[ ! -f "$ROOT/$df" ]]; then
    fail "$df missing"
    continue
  fi
  bad=""
  grep -q "OMP_NUM_THREADS=1" "$ROOT/$df" || bad="$bad OMP_NUM_THREADS"
  grep -q "OPENBLAS_NUM_THREADS=1" "$ROOT/$df" || bad="$bad OPENBLAS_NUM_THREADS"
  if [[ -n "$bad" ]]; then
    fail "$df lost thread pin(s):$bad - CSV would use every core on one platform"
  else
    ok "$df pins OMP + OPENBLAS to 1"
  fi
done

sharp="$ROOT/apps/thumbnail-generator/src/controllers/thumbnailController.js"
if [[ -f "$sharp" ]] && grep -q "sharp.concurrency(1)" "$sharp"; then
  ok "thumbnail pins sharp.concurrency(1)"
else
  fail "sharp.concurrency(1) missing from thumbnail-generator - Sharp would scale to all cores"
fi

# --- Dual entrypoint -------------------------------------------------------
# New code belongs in the shared app; both images must build from one tree.
section "dual entrypoint"
for key in "${APP_KEYS[@]}"; do
  dir="$ROOT/apps/$(app_name "$key")"
  miss=""
  [[ -f "$dir/Dockerfile" ]] || miss="$miss Dockerfile"
  [[ -f "$dir/Dockerfile.lambda" ]] || miss="$miss Dockerfile.lambda"
  if [[ -n "$miss" ]]; then
    fail "$(app_name "$key") missing:$miss"
  else
    ok "$(app_name "$key") has both Dockerfiles"
  fi
done

# --- Deployed configuration ------------------------------------------------
section "deployed configuration"
if [[ "$OFFLINE" -eq 1 ]]; then
  skip "--offline"
elif ! command -v aws >/dev/null 2>&1; then
  skip "aws CLI not on PATH"
elif ! aws sts get-caller-identity >/dev/null 2>&1; then
  warn "no AWS credentials - skipped deployed checks"
else
  # Lambda: identical memory/timeout/ephemeral across the three functions.
  lam_specs=""
  for key in "${APP_KEYS[@]}"; do
    spec="$(aws lambda get-function-configuration --region "$REGION" \
      --function-name "${PROJECT}-$(app_name "$key")" \
      --query '[MemorySize,Timeout,EphemeralStorage.Size]' --output text 2>/dev/null || true)"
    if [[ -z "$spec" ]]; then
      warn "lambda ${PROJECT}-$(app_name "$key") not found - enable_lambda off?"
      continue
    fi
    lam_specs="$lam_specs$spec\n"
  done
  uniq_lam="$(printf '%b' "$lam_specs" |  sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  if [[ "$uniq_lam" -gt 1 ]]; then
    fail "Lambda memory/timeout/ephemeral differ across apps:"
    printf '%b' "$lam_specs" |  sed '/^$/d' | sed 's/^/       /'
  elif [[ "$uniq_lam" -eq 1 ]]; then
    ok "Lambda spec identical across apps ($(printf '%b' "$lam_specs" | head -n 1 | tr '\t' '/'))"
  fi

  # ECS: identical cpu/memory across the three task definitions.
  ecs_specs=""
  for key in "${APP_KEYS[@]}"; do
    spec="$(aws ecs describe-task-definition --region "$REGION" \
      --task-definition "${PROJECT}-$(app_name "$key")" \
      --query 'taskDefinition.[cpu,memory]' --output text 2>/dev/null || true)"
    [[ -n "$spec" ]] && ecs_specs="$ecs_specs$spec\n"
  done
  uniq_ecs="$(printf '%b' "$ecs_specs" |  sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  if [[ "$uniq_ecs" -gt 1 ]]; then
    fail "ECS task cpu/memory differ across apps:"
    printf '%b' "$ecs_specs" |  sed '/^$/d' | sed 's/^/       /'
  elif [[ "$uniq_ecs" -eq 1 ]]; then
    ok "ECS task spec identical across apps ($(printf '%b' "$ecs_specs" | head -n 1 | tr '\t' '/'))"
  fi

  # EC2: one instance type for every app.
  types="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Platform,Values=ec2" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null || true)"
  if [[ -n "$types" ]]; then
    uniq_types="$(echo "$types" | tr '\t' '\n' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [[ "$(echo "$types" | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')" -gt 1 ]]; then
      fail "EC2 apps run mixed instance types: $uniq_types"
    else
      ok "EC2 instance type uniform ($uniq_types)"
    fi
  else
    warn "no running EC2 app instances tagged Platform=ec2"
  fi

  # EC2 pulls the :latest tag at boot. An instance launched before the current
  # image was pushed is running a different image than ECS and Lambda.
  for key in "${APP_KEYS[@]}"; do
    repo="$PROJECT/$(app_name "$key")"
    pushed="$(aws ecr describe-images --region "$REGION" --repository-name "$repo" \
      --image-ids "imageTag=$(tfvar ecr_image_tag)" \
      --query 'imageDetails[0].imagePushedAt' --output text 2>/dev/null || true)"
    launched="$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Platform,Values=ec2" \
      "Name=tag:App,Values=$key" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].LaunchTime' --output text 2>/dev/null || true)"
    [[ -n "$pushed" && -n "$launched" && "$pushed" != "None" && "$launched" != "None" ]] || continue
    launched="$(echo "$launched" | tr '\t' '\n' | sort | head -n 1)"
    if [[ "$pushed" > "$launched" ]]; then
      fail "$key: image pushed $pushed but EC2 launched $launched - EC2 is running older code than ECS/Lambda"
    else
      ok "$key: EC2 launched after the current :$(tfvar ecr_image_tag) image"
    fi
  done
fi

# --- Live metric surface ---------------------------------------------------
# Confirms the shared names are exposed by all nine running endpoints. The
# checks above only confirm they are declared in the source.
section "live /metrics"
if [[ "$OFFLINE" -eq 1 || "$SCRAPE" -eq 0 ]]; then
  skip "scrape disabled"
elif ! command -v curl >/dev/null 2>&1; then
  skip "curl not on PATH"
else
  alb="$(discover_alb_dns)"
  [[ -n "$alb" ]] || warn "ALB DNS not resolved - EC2/ECS scrape skipped"

  scrape_check() {
    local label="$1" url="$2"
    shift 2
    local body
    body="$(curl -sS --max-time 25 "$@" "$url" 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
      warn "$label unreachable - is it up? (make health)"
      return
    fi
    local missing=""
    for m in "${SHARED_METRICS[@]}"; do
      grep -q "^# HELP $m \|^$m[ {]" <<<"$body" || missing="$missing $m"
    done
    if [[ -n "$missing" ]]; then
      # Cold start only appears once a Lambda container has served a request.
      if [[ "$missing" == " app_cold_start_duration_seconds" && "$label" != *lambda* ]]; then
        ok "$label exposes all shared metrics (cold-start metric is Lambda-only)"
        return
      fi
      fail "$label is not exposing:$missing"
    else
      ok "$label exposes all ${#SHARED_METRICS[@]} shared metrics"
    fi
  }

  for key in "${APP_KEYS[@]}"; do
    if [[ -n "$alb" ]]; then
      for platform in ec2 ecs; do
        scrape_check "$key/$platform" "http://${alb}/metrics" -H "Host: $(discover_host "$key" "$platform")"
      done
    fi
    lurl="$(discover_lambda_url "$key")"
    if [[ -n "$lurl" ]]; then
      scrape_check "$key/lambda" "${lurl}/metrics"
    else
      warn "$key/lambda Function URL not resolved"
    fi
  done
fi

validate_summary "Fairness"
