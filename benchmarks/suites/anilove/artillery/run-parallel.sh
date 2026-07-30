#!/usr/bin/env bash
# Thin wrapper -> shared runner
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
exec bash "$ROOT/benchmarks/scripts/run-parallel.sh" anilove
