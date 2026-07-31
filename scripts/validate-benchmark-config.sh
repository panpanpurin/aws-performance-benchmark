#!/usr/bin/env bash
# Validate benchmark suite config before spending 30+ minutes on a run.
# Pure file inspection plus a local Docker query - no AWS calls, no cost.
#
#   ./scripts/validate-benchmark-config.sh
#   ./scripts/validate-benchmark-config.sh anilove
#   make validate-bench

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

FILTER="${1:-all}"
SUITES=(anilove csv-processor thumbnail-generator)

case "$FILTER" in
  all) ;;
  anilove | csv-processor | thumbnail-generator) SUITES=("$FILTER") ;;
  csv) SUITES=(csv-processor) ;;
  thumbnail) SUITES=(thumbnail-generator) ;;
  *)
    echo "Usage: $0 [all|anilove|csv-processor|thumbnail-generator]" >&2
    exit 1
    ;;
esac

# suite -> prometheus grafana pg_ecs pg_ec2 pg_lambda project targets_key
suite_meta() {
  case "$1" in
    anilove) echo "9090 3002 9092 9093 9094 anilove-benchmark anilove" ;;
    csv-processor) echo "9190 3102 9192 9193 9194 csv-processor-benchmark csv" ;;
    thumbnail-generator) echo "9290 3202 9292 9293 9294 thumbnail-generator-benchmark thumbnail" ;;
  esac
}

# First scalar value for a key, quotes and carriage returns stripped.
yaml_scalar() {
  sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" |
    head -n 1 |
    tr -d '\r' |
    sed 's/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//'
}

# Host port from a pushgateway URL (http://localhost:9093).
pushgateway_port() {
  sed -n 's#.*pushgateway:[[:space:]]*"\?http://localhost:\([0-9]\{1,\}\)"\?.*#\1#p' "$1" | head -n 1
}

# job_name|targets|instance-label, one record per scrape_config.
prometheus_jobs() {
  awk '
    /^[[:space:]]*-[[:space:]]*job_name:/ {
      if (job != "") print job "|" tgt "|" inst
      job = $0; sub(/^.*job_name:[[:space:]]*/, "", job); gsub(/["'\''\r]/, "", job)
      tgt = ""; inst = ""
    }
    /^[[:space:]]*-[[:space:]]*targets:/ {
      t = $0; sub(/^.*targets:[[:space:]]*/, "", t); gsub(/\r/, "", t); tgt = tgt t
    }
    /^[[:space:]]*instance:[[:space:]]*/ {
      i = $0; sub(/^.*instance:[[:space:]]*/, "", i); gsub(/["'\''\r]/, "", i); inst = i
    }
    END { if (job != "") print job "|" tgt "|" inst }
  ' "$1"
}

echo "=== Benchmark config validation ==="
echo "suites: ${SUITES[*]}"

# --- Compose feature level -------------------------------------------------
# Suites use `include:`, which Compose only understands from v2.20.
section "docker compose"
if command -v docker >/dev/null 2>&1; then
  cv="$(docker compose version --short 2>/dev/null | tr -d 'v\r' || true)"
  if [[ -z "$cv" ]]; then
    warn "docker compose version unreadable (daemon down?) - 'include:' needs v2.20+"
  else
    cv_maj="${cv%%.*}"
    cv_rest="${cv#*.}"
    cv_min="${cv_rest%%.*}"
    if [[ "$cv_maj" =~ ^[0-9]+$ ]] && [[ "$cv_min" =~ ^[0-9]+$ ]] &&
      { ((cv_maj > 2)) || { ((cv_maj == 2)) && ((cv_min >= 20)); }; }; then
      ok "compose v$cv supports include:"
    else
      fail "compose v$cv is below v2.20 - suites cannot resolve 'include:'"
    fi
  fi
else
  skip "docker not on PATH"
fi

# --- Per-suite checks ------------------------------------------------------
for suite in "${SUITES[@]}"; do
  read -r P_PROM P_GRAF P_PG_ECS P_PG_EC2 P_PG_LAMBDA PROJECT_NAME TKEY <<<"$(suite_meta "$suite")"

  section "$suite"
  sdir="$ROOT/benchmarks/suites/$suite"
  adir="$sdir/artillery"

  missing=0
  for f in \
    "$sdir/docker-compose.yml" \
    "$sdir/prometheus.yml" \
    "$sdir/grafana/dashboard.json" \
    "$adir/test-ec2.yml" \
    "$adir/test-ecs.yml" \
    "$adir/test-lambda.yml"; do
    if [[ ! -f "$f" ]]; then
      fail "missing ${f#"$ROOT"/}"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    continue
  fi
  ok "suite files present"

  # -- Artillery targets --
  alb_ec2="$(yaml_scalar "$adir/test-ec2.yml" target)"
  alb_ecs="$(yaml_scalar "$adir/test-ecs.yml" target)"
  lam_url="$(yaml_scalar "$adir/test-lambda.yml" target)"

  for pair in "ec2:$alb_ec2" "ecs:$alb_ecs" "lambda:$lam_url"; do
    plat="${pair%%:*}"
    val="${pair#*:}"
    if [[ -z "$val" ]]; then
      fail "test-$plat.yml has no target:"
    elif [[ "$val" == *REPLACE_ME* ]]; then
      fail "test-$plat.yml target is still the REPLACE_ME placeholder - run: make sync-targets"
    else
      ok "test-$plat.yml target set"
    fi
  done

  # EC2 and ECS share one ALB; only the Host header may differ.
  if [[ -n "$alb_ec2" && -n "$alb_ecs" && "$alb_ec2" != "$alb_ecs" ]]; then
    fail "EC2 and ECS point at different ALBs ($alb_ec2 vs $alb_ecs) - only the Host header should differ"
  fi
  # Only meaningful once the placeholder has been replaced; an unfilled target
  # is already reported above.
  if [[ -n "$lam_url" && "$lam_url" != *REPLACE_ME* && "$lam_url" != *lambda-url* ]]; then
    fail "test-lambda.yml target is not a Function URL: $lam_url"
  fi

  # -- Host headers: the ALB routes by hostname, so EC2/ECS need distinct ones --
  host_ec2="$(yaml_scalar "$adir/test-ec2.yml" Host)"
  host_ecs="$(yaml_scalar "$adir/test-ecs.yml" Host)"
  host_lambda="$(yaml_scalar "$adir/test-lambda.yml" Host)"

  if [[ -z "$host_ec2" ]]; then
    fail "test-ec2.yml has no Host header - ALB cannot route it"
  elif [[ -z "$host_ecs" ]]; then
    fail "test-ecs.yml has no Host header - ALB cannot route it"
  elif [[ "$host_ec2" == "$host_ecs" ]]; then
    fail "EC2 and ECS share Host '$host_ec2' - both loads would hit one platform"
  else
    ok "Host headers distinct ($host_ec2 / $host_ecs)"
  fi
  if [[ -n "$host_lambda" ]]; then
    warn "test-lambda.yml sets a Host header - Lambda uses Function URLs, not the ALB"
  fi

  # -- Pushgateway ports: a port belonging to another suite sends this suite's
  #    Artillery metrics to that suite's pushgateway --
  for pair in "ec2:$P_PG_EC2" "ecs:$P_PG_ECS" "lambda:$P_PG_LAMBDA"; do
    plat="${pair%%:*}"
    want="${pair#*:}"
    got="$(pushgateway_port "$adir/test-$plat.yml")"
    if [[ -z "$got" ]]; then
      warn "test-$plat.yml has no pushgateway config - Artillery metrics will not reach Prometheus"
    elif [[ "$got" != "$want" ]]; then
      fail "test-$plat.yml pushes to :$got, expected :$want for $suite"
    else
      ok "test-$plat.yml pushgateway :$got"
    fi
  done

  # -- Processor files referenced by the YAML must exist --
  for plat in ec2 ecs lambda; do
    proc="$(yaml_scalar "$adir/test-$plat.yml" processor)"
    if [[ -n "$proc" && ! -f "$adir/${proc#./}" ]]; then
      fail "test-$plat.yml references missing processor $proc"
    fi
  done

  # -- Prometheus scrape config --
  prom="$sdir/prometheus.yml"
  found_jobs=""
  prom_before="$VALIDATE_FAILED"
  while IFS='|' read -r job tgt inst; do
    [[ -n "$job" ]] || continue
    found_jobs="$found_jobs $job"
    norm="$(echo "$tgt" | tr -d '[:space:]')"
    if [[ -z "$norm" || "$norm" == "[]" ]]; then
      fail "prometheus.yml job '$job' has empty targets - fill per benchmarks/docs/PROMETHEUS-TARGETS.md"
      continue
    fi
    case "$job" in
      *-ec2) want_inst=ec2 ;;
      *-ecs) want_inst=ecs ;;
      *-lambda) want_inst=lambda ;;
      *) want_inst="" ;;
    esac
    if [[ -n "$want_inst" && -n "$inst" && "$inst" != "$want_inst" ]]; then
      fail "prometheus.yml job '$job' labels instance='$inst', expected '$want_inst' - dashboards split on this label"
    fi
  done < <(prometheus_jobs "$prom")

  for job in instrumented-metrics-ec2 instrumented-metrics-ecs instrumented-metrics-lambda \
    artillery-metrics-ec2 artillery-metrics-ecs artillery-metrics-lambda; do
    case " $found_jobs " in
      *" $job "*) ;;
      *) fail "prometheus.yml missing job '$job'" ;;
    esac
  done
  if [[ "$VALIDATE_FAILED" -eq "$prom_before" ]]; then
    ok "prometheus.yml scrape jobs complete"
  fi

  # -- Compose project name and host port remaps --
  compose="$sdir/docker-compose.yml"
  cname="$(yaml_scalar "$compose" name)"
  if [[ "$cname" != "$PROJECT_NAME" ]]; then
    fail "docker-compose.yml project name '$cname', expected '$PROJECT_NAME' - suites must not share a project"
  fi
  for port in "$P_PROM:9090" "$P_GRAF:3000" "$P_PG_ECS:9091" "$P_PG_EC2:9091" "$P_PG_LAMBDA:9091"; do
    if ! grep -q "\"$port\"" "$compose"; then
      fail "docker-compose.yml does not map $port"
    fi
  done
  ok "compose project '$cname', ports $P_PROM/$P_GRAF/$P_PG_ECS-$P_PG_LAMBDA"

  # -- Cross-check against terraform outputs when they exist --
  if [[ -f "$TARGETS_FILE" ]]; then
    tgt_before="$VALIDATE_FAILED"
    alb_dns="$(json_get alb_dns || true)"
    want_lambda="$(json_get_nested "lambda_urls.$TKEY" || true)"
    want_h_ec2="$(json_get_nested "hostnames.${TKEY}_ec2" || true)"
    want_h_ecs="$(json_get_nested "hostnames.${TKEY}_ecs" || true)"

    if [[ -n "$alb_dns" && "$alb_ec2" != *"$alb_dns"* ]]; then
      fail "test-ec2.yml target does not match terraform alb_dns ($alb_dns) - run: make sync-targets"
    fi
    if [[ -n "$want_lambda" && "${lam_url%/}" != "${want_lambda%/}" ]]; then
      fail "test-lambda.yml target is stale vs terraform ($want_lambda) - run: make sync-targets"
    fi
    if [[ -n "$want_h_ec2" && "$host_ec2" != "$want_h_ec2" ]]; then
      fail "test-ec2.yml Host '$host_ec2' does not match terraform '$want_h_ec2'"
    fi
    if [[ -n "$want_h_ecs" && "$host_ecs" != "$want_h_ecs" ]]; then
      fail "test-ecs.yml Host '$host_ecs' does not match terraform '$want_h_ecs'"
    fi
    if [[ "$VALIDATE_FAILED" -eq "$tgt_before" ]]; then
      ok "matches benchmark-targets.json"
    fi
  else
    warn "no ${TARGETS_FILE#"$ROOT"/} - targets not cross-checked against terraform"
  fi
done

# --- Port collision: local stack owns the same ports as the anilove suite ---
section "port conflicts"
case " ${SUITES[*]} " in
  *" anilove "*)
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      running="$(docker compose ls --format json 2>/dev/null || true)"
      if [[ "$running" == *aws-benchmark-local* ]]; then
        fail "local stack is up on 9090/3002/9092-9094 - 'make local-down' before the anilove suite"
      else
        ok "local stack not holding anilove ports"
      fi
    else
      skip "docker daemon not reachable"
    fi
    ;;
  *) skip "anilove not in scope" ;;
esac

validate_summary "Benchmark config"
