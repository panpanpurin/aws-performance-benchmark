#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo ""
echo "=== Local Artillery (Docker apps on localhost) ==="
echo "Prerequisite: local stack running"
echo "  make local-up"
echo "  # or: docker compose up -d --build"
echo ""

if [[ ! -d node_modules ]]; then
  echo "Installing dependencies..."
  npm install
fi

run_one() {
  echo "[$1] ..."
  npx artillery run "$2"
}

case "${1:-all}" in
  anilove)   run_one AniLove test-anilove-local.yml ;;
  csv)       run_one CSV test-csv-local.yml ;;
  thumbnail) run_one Thumbnail test-thumbnail-local.yml ;;
  all)
    run_one AniLove test-anilove-local.yml
    run_one CSV test-csv-local.yml
    run_one Thumbnail test-thumbnail-local.yml
    echo ""
    echo "All local tests finished."
    ;;
  *)
    echo "Usage: $0 [anilove|csv|thumbnail|all]"
    exit 1
    ;;
esac
