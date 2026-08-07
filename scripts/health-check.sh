#!/usr/bin/env bash
# Smoke-check ALB (with Host) and Lambda Function URLs.
#
#   ./scripts/health-check.sh
#   make health

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_targets
need curl
need node

fail=0

check_http() {
  local name="$1" url="$2"
  shift 2
  local code
  code="$(curl -sS -o /tmp/hb-body.txt -w "%{http_code}" --max-time 20 "$@" "$url" || echo "000")"
  if [[ "$code" == "200" ]]; then
    echo "OK  $name ($code)"
  else
    echo "FAIL $name ($code) $url" >&2
    fail=1
  fi
}

if command -v cygpath >/dev/null 2>&1; then
  TARGETS_NODE="$(cygpath -m "$TARGETS_FILE")"
else
  TARGETS_NODE="$TARGETS_FILE"
fi

SCHEME="$(discover_scheme)"

# HTTPS resolves by name; HTTP needs the Host header to route.
echo "=== ALB app /health ($SCHEME) ==="
while IFS=$'\t' read -r key host; do
  [[ -n "$host" ]] || continue
  if [[ "$SCHEME" == "https" ]]; then
    check_http "$key" "https://${host}/health"
  else
    alb="$(json_get alb_dns)"
    check_http "$key" "http://${alb}/health" -H "Host: ${host}"
  fi
done < <(node -e "
const t=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
for (const [k,v] of Object.entries(t.hostnames||{}).sort()) console.log(k+'\t'+v);
" "$TARGETS_NODE")

echo
echo "=== Lambda Function URL /health ==="
while IFS=$'\t' read -r key url; do
  [[ -n "$url" ]] || continue
  u="${url%/}/health"
  check_http "lambda/$key" "$u"
done < <(node -e "
const t=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
for (const [k,v] of Object.entries(t.lambda_urls||{}).sort()) console.log(k+'\t'+v);
" "$TARGETS_NODE")

echo
echo "=== Local Prometheus / Grafana ==="
if curl -sS --max-time 3 "http://localhost:9090/-/ready" >/dev/null 2>&1; then
  echo "OK  prometheus :9090"
else
  echo "WARN prometheus :9090 not ready (make bench-anilove?)"
fi
if curl -sS --max-time 3 "http://localhost:3002/api/health" >/dev/null 2>&1; then
  echo "OK  grafana :3002"
else
  echo "WARN grafana :3002 not ready"
fi

echo
if [[ "$fail" -ne 0 ]]; then
  echo "Some checks failed." >&2
  exit 1
fi
echo "All remote health checks passed."
