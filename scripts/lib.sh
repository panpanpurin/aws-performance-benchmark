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

export MSYS_NO_PATHCONV=1
