#!/usr/bin/env bash
# Verify local tools needed for this repo.
#
#   ./scripts/check-prereqs.sh
#   make check

set -euo pipefail

fail=0
check() {
  if command -v "$1" >/dev/null 2>&1; then
    ver="$($2 2>/dev/null | head -n 1 || true)"
    echo "OK  $1  ${ver}"
  else
    echo "MISS $1  ($3)"
    fail=1
  fi
}

# Help Git Bash find common Windows install paths
export PATH="/c/Program Files/nodejs:/c/Program Files/Amazon/AWSCLIV2:${APPDATA:-}/npm:$PATH"

echo "=== Prerequisites ==="
check bash "bash --version" "Git Bash / WSL / Linux"
check aws "aws --version" "AWS CLI v2"
check docker "docker --version" "Docker Desktop"
check terraform "terraform version" "Terraform >= 1.5"
check node "node --version" "Node.js LTS"
check make "make --version" "GNU Make"

if command -v artillery >/dev/null 2>&1 || [[ -x "${APPDATA:-}/npm/artillery.cmd" ]]; then
  echo "OK  artillery"
elif command -v npx >/dev/null 2>&1 || [[ -x "/c/Program Files/nodejs/npx.cmd" ]]; then
  echo "OK  npx (will fetch artillery@2.0.23)"
else
  echo "MISS artillery/npx  (npm install -g artillery@2.0.23)"
  fail=1
fi


if aws sts get-caller-identity >/dev/null 2>&1; then
  echo "OK  aws identity  $(aws sts get-caller-identity --query Account --output text)"
else
  echo "MISS aws credentials  (aws configure)"
  fail=1
fi

if docker info >/dev/null 2>&1; then
  echo "OK  docker daemon"
else
  echo "MISS docker daemon  (start Docker Desktop)"
  fail=1
fi

echo
if [[ "$fail" -ne 0 ]]; then
  echo "Some prerequisites missing." >&2
  exit 1
fi
echo "All prerequisites OK."
