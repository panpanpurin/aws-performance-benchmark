#!/usr/bin/env bash
# Copy generated figures into paper/fig/, or report drift.
#
#   bash scripts/sync-paper-figures.sh          # copy
#   bash scripts/sync-paper-figures.sh --check  # report only, non-zero on drift
#   make paper-figures | make paper-figures-check
#
# The paper \input{}s these, so a hand-copied paper/fig/ can silently lag the
# data. Copies are verbatim: the "Do not edit" header travels with the file.
# Regenerate the sources first with make figure-split-*, figure-condition-* and
# figure-<suite> RUN=<run-id>.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

cd "$ROOT"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

DEST="paper/fig"
copied=0
drift=0
missing=0

[[ -d "$DEST" ]] || mkdir -p "$DEST"

for src in benchmarks/suites/*/figures/*.tex benchmarks/suites/*/figures/*.svg; do
  [[ -e "$src" ]] || continue
  dst="$DEST/$(basename "$src")"

  if [[ ! -f "$dst" ]]; then
    if [[ "$CHECK" -eq 1 ]]; then
      fail "$(basename "$src") is not in $DEST"
      missing=$((missing + 1))
    else
      cp "$src" "$dst"
      ok "added $(basename "$src")"
      copied=$((copied + 1))
    fi
    continue
  fi

  if cmp -s "$src" "$dst"; then
    continue
  fi

  if [[ "$CHECK" -eq 1 ]]; then
    fail "$(basename "$src") in $DEST differs from the generated figure"
    drift=$((drift + 1))
  else
    cp "$src" "$dst"
    ok "updated $(basename "$src")"
    copied=$((copied + 1))
  fi
done

# Figures in paper/fig with no generator left, e.g. a renamed suite.
for dst in "$DEST"/*.tex "$DEST"/*.svg; do
  [[ -e "$dst" ]] || continue
  base="$(basename "$dst")"
  if ! ls benchmarks/suites/*/figures/"$base" >/dev/null 2>&1; then
    warn "$base has no generated source"
  fi
done

if [[ "$CHECK" -eq 1 ]]; then
  if [[ "$drift" -eq 0 && "$missing" -eq 0 ]]; then
    ok "paper/fig matches the generated figures"
    exit 0
  fi
  echo "paper/fig: $drift stale, $missing missing. Run: make paper-figures" >&2
  exit 1
fi

if [[ "$copied" -eq 0 ]]; then
  ok "paper/fig already up to date"
else
  ok "paper/fig: $copied file(s) written"
fi
