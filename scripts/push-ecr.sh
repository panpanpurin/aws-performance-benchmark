#!/usr/bin/env bash
# Build and push EC2/ECS (:latest) and Lambda (:lambda) images to ECR.
# Run from repo root. Needs: AWS CLI credentials, Docker.
#
#   ./scripts/push-ecr.sh
#   ./scripts/push-ecr.sh anilove
#   REGION=ap-northeast-1 PROJECT=aws-perf-bench ./scripts/push-ecr.sh

set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-aws-perf-bench}"
FILTER="${1:-all}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "Account  ${ACCOUNT}"
echo "Region   ${REGION}"
echo "Registry ${REGISTRY}"
echo

echo "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"

push_one() {
  local name="$1" dir="$2" repo="$3" dockerfile="$4" tag="$5"
  local context="${ROOT}/${dir}"
  local local_ref="${repo}:${tag}"
  local remote_ref="${REGISTRY}/${repo}:${tag}"

  echo
  echo "==> Build ${name} (${tag}) from ${dockerfile}"
  docker build -t "$local_ref" -f "${context}/${dockerfile}" "$context"
  docker tag "$local_ref" "$remote_ref"
  echo "==> Push ${remote_ref}"
  docker push "$remote_ref"
}

push_app() {
  local name="$1" dir="$2" repo="$3"
  push_one "$name" "$dir" "$repo" "Dockerfile" "latest"
  push_one "$name" "$dir" "$repo" "Dockerfile.lambda" "lambda"
}

case "$FILTER" in
  all)
    push_app anilove apps/anilove "${PROJECT}/anilove"
    push_app csv apps/csv-processor "${PROJECT}/csv-processor"
    push_app thumbnail apps/thumbnail-generator "${PROJECT}/thumbnail-generator"
    ;;
  anilove)
    push_app anilove apps/anilove "${PROJECT}/anilove"
    ;;
  csv)
    push_app csv apps/csv-processor "${PROJECT}/csv-processor"
    ;;
  thumbnail)
    push_app thumbnail apps/thumbnail-generator "${PROJECT}/thumbnail-generator"
    ;;
  *)
    echo "Usage: $0 [all|anilove|csv|thumbnail]" >&2
    exit 1
    ;;
esac

echo
echo "Done. Filter=${FILTER}"
echo "Next: set enable_ec2/ecs/lambda = true in terraform.tfvars and run make apply"
