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

# Metric names are identical across all apps and platforms so that one Grafana
# dashboard can split series by the `instance` label (ec2/ecs/lambda). See
# apps/anilove/src/metrics.js for the reference implementation and
# docs/WORKLOADS.md for what each metric measures.
SHARED_METRICS=(
  app_total_execution_time_seconds
  app_internal_processing_time_seconds
  app_cold_start_duration_seconds
  app_cpu_seconds_total
  app_cpu_usage_percent
  app_cpu_peak_percent
  app_ram_usage_mb
  app_ram_peak_mb
)

# prometheus_client strips a trailing _total and re-appends it at exposition;
# prom-client does not. The live /metrics scrape below proves they agree.

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
  #
  # _bucket/_sum/_count are derived from a histogram, not declared, and appear
  # here only inside PromQL in comments.
  while read -r extra; do
    [[ -n "$extra" ]] || continue
    case "$extra" in
      *_bucket|*_sum|*_count) continue ;;
    esac
    case " ${SHARED_METRICS[*]} " in
      *" $extra "*) ;;
      *) warn "$key defines '$extra', which the other apps do not - not comparable" ;;
    esac
  # Requires a name after the prefix: prose refers to the family as "app_*".
  done < <(grep -oE 'app_[a-z][a-z0-9_]*' "$src" | sort -u)
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

# Every request uploads the same fixture with the same params, so the libvips
# operation cache would turn the workload into a cache lookup. It would also not
# degrade equally: the cache is memory-bounded, and Lambda has 1769 MB against
# 1024 MB elsewhere.
if [[ -f "$sharp" ]] && grep -q "sharp.cache(false)" "$sharp"; then
  ok "thumbnail disables the sharp/libvips operation cache"
else
  fail "sharp.cache(false) missing from thumbnail-generator (identical fixtures would be served from cache)".
fi

# app_cpu_usage_percent must be a percentage of the one vCPU each worker is
# allocated. os.cpus() reads the host rather than the cgroup, so using it as the
# divisor both halves the figure inside a --cpus=1 container and can differ
# between EC2/ECS and the Lambda sandbox, biasing a metric the paper reports.
section "CPU normalisation"
for key in "${APP_KEYS[@]}"; do
  src="$ROOT/$(metrics_source "$key")"
  [[ -f "$src" ]] || continue
  # Comments explaining why os.cpus() is not used are fine; a live divisor is not.
  if grep -vE '^\s*(//|#)' "$src" | grep -qE 'os\.cpus\(\)|cpu_count\(\)'; then
    fail "$key divides CPU percent by the host core count - use the allocated 1 vCPU"
  else
    ok "$key normalises CPU against the allocated vCPU"
  fi
done

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

# --- Build reproducibility -------------------------------------------------
# A rebuild resolving different library versions measures a different system.
# sharp is the thumbnail workload's cost and numpy is the csv workload's.
section "build reproducibility"

for key in "${APP_KEYS[@]}"; do
  dir="$ROOT/apps/$(app_name "$key")"

  # Node apps: lockfile committed, and images installing from it.
  if [[ -f "$dir/package.json" ]]; then
    if [[ -f "$dir/package-lock.json" ]]; then
      ok "$(app_name "$key") has package-lock.json"
    else
      fail "$(app_name "$key") has no package-lock.json - versions resolve at build time"
    fi
    for df in Dockerfile Dockerfile.lambda; do
      [[ -f "$dir/$df" ]] || continue
      if grep -qE '^\s*RUN\s+npm\s+ci\b' "$dir/$df"; then
        ok "$(app_name "$key")/$df uses npm ci"
      elif grep -qE '^\s*RUN\s+npm\s+install\b' "$dir/$df"; then
        fail "$(app_name "$key")/$df uses npm install - ignores the lockfile, use npm ci"
      fi
    done

    # A lockfile excluded by .dockerignore is equivalent to no lockfile; npm ci
    # then fails inside the image.
    if [[ -f "$dir/.dockerignore" ]] &&
       grep -qE '^\s*package-lock\.json\s*$' "$dir/.dockerignore"; then
      fail "$(app_name "$key")/.dockerignore excludes package-lock.json - npm ci cannot see it"
    else
      ok "$(app_name "$key") ships package-lock.json into the build context"
    fi
  fi

  # Every base image pinned by digest, not by a moving tag.
  for df in Dockerfile Dockerfile.lambda; do
    [[ -f "$dir/$df" ]] || continue
    while read -r from_line; do
      [[ -z "$from_line" ]] && continue
      if [[ "$from_line" == *"@sha256:"* ]]; then
        ok "$(app_name "$key")/$df base image pinned by digest"
      else
        fail "$(app_name "$key")/$df FROM is a moving tag: ${from_line#FROM }"
      fi
    done < <(grep -E '^FROM ' "$dir/$df" || true)
  done
done

# Python: direct pins are necessary but not sufficient, because pandas pulls
# numpy in transitively and declares only a lower bound.
req="$ROOT/apps/csv-processor/requirements.txt"
if [[ -f "$req" ]]; then
  if grep -qE '^\s*[A-Za-z0-9_.-]+\s*(~=|>=|<|>)' "$req"; then
    fail "requirements.txt has a non-exact pin - every direct dependency must use =="
  else
    ok "requirements.txt pins every direct dependency exactly"
  fi
  if grep -q '^# GENERATED by scripts/lock-python-deps.sh' "$req"; then
    ok "requirements.txt is a full transitive lock"
  else
    warn "requirements.txt pins direct deps only - numpy still floats; run: make lock-deps"
  fi
fi

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

  # Worker counts. Provisioned capacity is only equal if each platform serves
  # with the same number of workers: one EC2 container, one ECS task, and one
  # Lambda sandbox. An uncapped Lambda scales to the account limit and would
  # have many times the aggregate CPU of the other two under load.
  want_workers="$(tfvar lambda_reserved_concurrency)"
  : "${want_workers:=1}"

  # A deliberate elasticity run and a temporary quota workaround both read -1.
  # tfvars carries a marker to tell them apart; clearing it clears this.
  if grep -q 'TEMPORARY-UNCAPPED' "$ROOT/terraform/terraform.tfvars" 2>/dev/null; then
    fail "terraform.tfvars is marked TEMPORARY-UNCAPPED - Lambda is uncapped as a quota workaround, not by design; no measurement run in this state is valid"
  fi
  for key in "${APP_KEYS[@]}"; do
    rc="$(aws lambda get-function-concurrency --region "$REGION" \
      --function-name "${PROJECT}-$(app_name "$key")" \
      --query 'ReservedConcurrentExecutions' --output text 2>/dev/null || true)"
    [[ -n "$rc" ]] || continue
    if [[ "$rc" == "None" ]]; then
      if [[ "$want_workers" == "-1" ]]; then
        warn "$key/lambda uncapped by design - measures elasticity, not per-request cost"
      else
        fail "$key/lambda has no reserved concurrency but tfvars asks for $want_workers - Lambda can outscale EC2/ECS"
      fi
    elif [[ "$rc" != "$want_workers" ]]; then
      fail "$key/lambda reserved concurrency is $rc, tfvars says $want_workers"
    else
      ok "$key/lambda capped at $rc concurrent execution(s)"
    fi
  done

  ecs_desired="$(aws ecs describe-services --region "$REGION" --cluster "${PROJECT}-cluster" \
    --services anilove csv-processor thumbnail-generator \
    --query 'services[].desiredCount' --output text 2>/dev/null || true)"
  if [[ -n "$ecs_desired" ]]; then
    for d in $ecs_desired; do
      if [[ "$d" != "0" && "$want_workers" != "-1" && "$d" != "$want_workers" ]]; then
        warn "an ECS service runs $d tasks while lambda is capped at $want_workers - worker counts differ"
      fi
    done
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

  # Read the limits off the
  # running container over SSM and compare them with terraform.tfvars.
  want_cpus="$(tfvar container_cpus)"
  : "${want_cpus:=1}"
  want_mem_mb="$(tfvar container_memory_mb)"
  : "${want_mem_mb:=1024}"
  want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%d", c * 1000000000}')
  want_bytes=$(( want_mem_mb * 1024 * 1024 ))

  for key in "${APP_KEYS[@]}"; do
    iid="$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Platform,Values=ec2" \
      "Name=tag:App,Values=$key" "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
    [[ -n "$iid" && "$iid" != "None" ]] || continue

    cid="$(aws ssm send-command --region "$REGION" --instance-ids "$iid" \
      --document-name "AWS-RunShellScript" \
      --comment "validate-fairness cpu limit" \
      --parameters "commands=[\"docker inspect $(app_name "$key") --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}'\"]" \
      --query 'Command.CommandId' --output text 2>/dev/null || true)"
    if [[ -z "$cid" || "$cid" == "None" ]]; then
      warn "$key: could not run docker inspect over SSM - container CPU limit unverified"
      continue
    fi

    out=""
    for _ in $(seq 1 15); do
      st="$(aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cid" --instance-id "$iid" \
        --query 'Status' --output text 2>/dev/null || echo Pending)"
      case "$st" in
        Success)
          out="$(aws ssm get-command-invocation --region "$REGION" \
            --command-id "$cid" --instance-id "$iid" \
            --query 'StandardOutputContent' --output text 2>/dev/null || true)"
          break
          ;;
        Failed | Cancelled | TimedOut) break ;;
      esac
      sleep 2
    done

    got_nano="$(echo "$out" | tr -d '\r' | awk 'NF{print $1; exit}')"
    got_bytes="$(echo "$out" | tr -d '\r' | awk 'NF{print $2; exit}')"
    if [[ -z "$got_nano" ]]; then
      warn "$key: no docker inspect output - container CPU limit unverified"
    elif [[ "$got_nano" == "0" ]]; then
      fail "$key: EC2 container runs with NO CPU limit - it gets the whole host, ECS/Lambda get 1 vCPU"
    elif [[ "$got_nano" != "$want_nano" ]]; then
      fail "$key: EC2 container capped at $((got_nano / 1000000)) mCPU, terraform.tfvars declares $want_cpus vCPU"
    elif [[ -n "$got_bytes" && "$got_bytes" != "$want_bytes" ]]; then
      fail "$key: EC2 container memory $((got_bytes / 1024 / 1024)) MB, terraform.tfvars declares $want_mem_mb MB"
    else
      ok "$key: EC2 container capped at $want_cpus vCPU / $want_mem_mb MB"
    fi
  done

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
  scheme="$(discover_scheme)"
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
        host="$(discover_host "$key" "$platform")"
        # HTTPS resolves by name; HTTP needs the Host header to route.
        if [[ "$scheme" == "https" ]]; then
          scrape_check "$key/$platform" "https://${host}/metrics"
        else
          scrape_check "$key/$platform" "http://${alb}/metrics" -H "Host: $host"
        fi
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
