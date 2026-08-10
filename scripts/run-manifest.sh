#!/usr/bin/env bash
# Snapshot what produced one run: code, images, host images, key config.
#
#   ./scripts/run-manifest.sh <suite> <run-id> <outdir>
#
# Written next to the Artillery logs as manifest-<run-id>.json. A campaign is
# five repetitions over several days; this is the record that they were the
# same. Never fails a run: a missing input becomes null.

set -uo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SUITE="${1:?usage: run-manifest.sh <suite> <run-id> <outdir>}"
RUN_ID="${2:?missing run id}"
OUTDIR="${3:?missing outdir}"

mkdir -p "$OUTDIR"
OUT="$OUTDIR/manifest-$RUN_ID.json"

# cd rather than git -C: lib.sh sets MSYS_NO_PATHCONV=1 for AWS parameter names,
# which leaves git on Windows unable to resolve an MSYS path passed as -C.
git_sha="$( (cd "$ROOT" && git rev-parse HEAD) 2>/dev/null || echo "")"
git_branch="$( (cd "$ROOT" && git rev-parse --abbrev-ref HEAD) 2>/dev/null || echo "")"
# The list, not just the flag: make sync-targets rewrites tracked files on every
# run, so the tree is never clean and the flag alone cannot separate a generated
# target from an uncommitted phase change.
git_status="$( (cd "$ROOT" && git status --porcelain) 2>/dev/null || echo "")"
git_dirty="false"
[[ -n "$git_status" ]] && git_dirty="true"

# Digests come from the generated file rather than terraform.tfvars, which is
# where push-ecr.sh writes them.
digest() {
  local f="$ROOT/terraform/image-digests.auto.tfvars"
  [[ -f "$f" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$f" | head -n 1 | tr -d '"\r'
}

if command -v cygpath >/dev/null 2>&1; then
  TARGETS_NODE="$(cygpath -m "$TARGETS_FILE")"
  OUT_NODE="$(cygpath -m "$OUT")"
else
  TARGETS_NODE="$TARGETS_FILE"
  OUT_NODE="$OUT"
fi

SUITE="$SUITE" RUN_ID="$RUN_ID" \
  GIT_SHA="$git_sha" GIT_BRANCH="$git_branch" GIT_DIRTY="$git_dirty" \
  GIT_DIRTY_FILES="$git_status" \
  EC2_AMI="$(tfvar ec2_ami_id)" ECS_AMI="$(tfvar ecs_ami_id)" \
  D_ANILOVE="$(digest image_digest_anilove)" \
  D_CSV="$(digest image_digest_csv)" \
  D_THUMB="$(digest image_digest_thumbnail)" \
  D_L_ANILOVE="$(digest image_digest_lambda_anilove)" \
  D_L_CSV="$(digest image_digest_lambda_csv)" \
  D_L_THUMB="$(digest image_digest_lambda_thumbnail)" \
  EC2_TYPE="$(tfvar ec2_instance_type)" ECS_TYPE="$(tfvar ecs_instance_type)" \
  TASK_CPU="$(tfvar ecs_task_cpu)" TASK_MEM="$(tfvar ecs_task_memory)" \
  LAMBDA_MEM="$(tfvar lambda_memory_mb)" \
  LAMBDA_CONC="$(tfvar lambda_reserved_concurrency)" \
  LAMBDA_ALB="$(tfvar lambda_behind_alb)" \
  RDS_CLASS="$(tfvar rds_instance_class)" \
  REGION_V="$(tfvar aws_region)" DOMAIN="$(tfvar domain_name)" \
  node -e '
const fs = require("fs");
const e = process.env;
const orNull = (v) => (v === undefined || v === "" ? null : v);

let targets = null;
try { targets = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}

const manifest = {
  run_id: e.RUN_ID,
  suite: e.SUITE,
  created_utc: new Date().toISOString(),
  git: {
    sha: orNull(e.GIT_SHA),
    branch: orNull(e.GIT_BRANCH),
    // true means the working tree did not match the commit when the run started
    dirty: e.GIT_DIRTY === "true",
    // Porcelain lines, so a reader can tell generated targets from real changes
    dirty_files: (e.GIT_DIRTY_FILES || "")
      .split("\n")
      .map((s) => s.trim())
      .filter(Boolean),
  },
  amis: { ec2: orNull(e.EC2_AMI), ecs: orNull(e.ECS_AMI) },
  image_digests: {
    anilove: orNull(e.D_ANILOVE),
    csv: orNull(e.D_CSV),
    thumbnail: orNull(e.D_THUMB),
    lambda_anilove: orNull(e.D_L_ANILOVE),
    lambda_csv: orNull(e.D_L_CSV),
    lambda_thumbnail: orNull(e.D_L_THUMB),
  },
  config: {
    region: orNull(e.REGION_V),
    domain: orNull(e.DOMAIN),
    ec2_instance_type: orNull(e.EC2_TYPE),
    ecs_instance_type: orNull(e.ECS_TYPE),
    ecs_task_cpu: orNull(e.TASK_CPU),
    ecs_task_memory: orNull(e.TASK_MEM),
    lambda_memory_mb: orNull(e.LAMBDA_MEM),
    lambda_reserved_concurrency: orNull(e.LAMBDA_CONC),
    lambda_behind_alb: orNull(e.LAMBDA_ALB),
    rds_instance_class: orNull(e.RDS_CLASS),
  },
  targets: targets && {
    scheme: targets.scheme || null,
    alb_dns: targets.alb_dns || null,
    hostnames: targets.hostnames || null,
    lambda_urls: targets.lambda_urls || null,
  },
};

fs.writeFileSync(process.argv[2], JSON.stringify(manifest, null, 2) + "\n");
' "$TARGETS_NODE" "$OUT_NODE"

echo "manifest: ${OUT#"$ROOT"/}"

# Unpinned images or a dirty tree make a repetition hard to reproduce later.
if [[ "$git_dirty" == "true" ]]; then
  n_dirty="$(printf '%s\n' "$git_status" | grep -c . || true)"
  echo "  WARN working tree is dirty ($n_dirty file(s)) - listed in git.dirty_files" >&2
fi
if [[ -z "$(digest image_digest_anilove)$(digest image_digest_csv)$(digest image_digest_thumbnail)" ]]; then
  echo "  WARN no image digests pinned - run make push-images" >&2
fi
