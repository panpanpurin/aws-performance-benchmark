#!/usr/bin/env bash
# Build and push EC2/ECS (:latest) and Lambda (:lambda) images to ECR.
# Lambda needs a single-platform Docker V2 manifest (not an OCI image index).
#
#   ./scripts/push-ecr.sh
#   ./scripts/push-ecr.sh anilove
#   REGION=ap-northeast-1 PROJECT=aws-perf-bench ./scripts/push-ecr.sh all

set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-aws-perf-bench}"
FILTER="${1:-all}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 127; }; }
need aws
need docker

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "Account  ${ACCOUNT}"
echo "Region   ${REGION}"
echo "Registry ${REGISTRY}"
echo

echo "Logging in to ECR..."
# Git Bash/MSYS: prevent path conversion breaking the registry URL
export MSYS_NO_PATHCONV=1
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"

push_one() {
  local name="$1" dir="$2" repo="$3" dockerfile="$4" tag="$5" for_lambda="$6"
  local context="${ROOT}/${dir}"
  local local_ref="${repo}:${tag}"
  local remote_ref="${REGISTRY}/${repo}:${tag}"

  echo
  echo "==> Build ${name} (${tag}) from ${dockerfile}"

  # Relative context: $ROOT is an MSYS path Docker Desktop cannot resolve, and
  # this repo path also has a space and a non-ASCII character.
  (
    cd "$context" || exit 1
    if [[ "$for_lambda" == "1" ]]; then
      # Classic builder avoids OCI index / attestations that Lambda rejects
      DOCKER_BUILDKIT=0 docker build --platform linux/amd64 \
        -t "$local_ref" -f "$dockerfile" . ||
        docker buildx build --platform linux/amd64 --provenance=false --sbom=false --load \
          -t "$local_ref" -f "$dockerfile" .
    else
      docker build --platform linux/amd64 \
        -t "$local_ref" -f "$dockerfile" .
    fi
  )

  docker tag "$local_ref" "$remote_ref"
  echo "==> Push ${remote_ref}"
  docker push "$remote_ref"

  if [[ "$for_lambda" == "1" ]]; then
    media="$(aws ecr batch-get-image \
      --region "$REGION" \
      --repository-name "$repo" \
      --image-ids "imageTag=${tag}" \
      --query 'images[0].imageManifestMediaType' \
      --output text)"
    echo "    mediaType=${media}"
    if [[ "$media" == *index* ]]; then
      echo "ERROR: Lambda image is still an OCI index. Rebuild with DOCKER_BUILDKIT=0." >&2
      exit 1
    fi
  fi
}

push_app() {
  local name="$1" dir="$2" repo="$3"
  push_one "$name" "$dir" "$repo" "Dockerfile" "latest" 0
  push_one "$name" "$dir" "$repo" "Dockerfile.lambda" "lambda" 1
}

case "$FILTER" in
  all)
    push_app anilove apps/anilove "${PROJECT}/anilove"
    push_app csv apps/csv-processor "${PROJECT}/csv-processor"
    push_app thumbnail apps/thumbnail-generator "${PROJECT}/thumbnail-generator"
    ;;
  anilove) push_app anilove apps/anilove "${PROJECT}/anilove" ;;
  csv) push_app csv apps/csv-processor "${PROJECT}/csv-processor" ;;
  thumbnail) push_app thumbnail apps/thumbnail-generator "${PROJECT}/thumbnail-generator" ;;
  *)
    echo "Usage: $0 [all|anilove|csv|thumbnail]" >&2
    exit 1
    ;;
esac

echo
echo "Done. Filter=${FILTER}"
echo "Next: enable_ec2/ecs/lambda = true in terraform.tfvars, then make apply"
