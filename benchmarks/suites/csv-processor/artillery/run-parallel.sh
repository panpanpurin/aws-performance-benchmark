#!/usr/bin/env bash
# Thin wrapper -> shared runner
exec "$(cd "$(dirname "$0")/../../../scripts" && pwd)/run-parallel.sh" csv-processor
