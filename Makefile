# Run from repo root. Scripts are bash (.sh) + Node.
# On Windows: Git Bash, WSL, or bash on PATH.

GIT_BASH := $(wildcard C:/PROGRA~1/Git/bin/bash.exe)
ifeq ($(GIT_BASH),)
  GIT_BASH := $(wildcard C:/PROGRA~2/Git/bin/bash.exe)
endif
BASH := $(if $(GIT_BASH),$(GIT_BASH),bash)
#
#   make help
#   make check
#   make apply
#   make push-images
#   make sync-targets
#   make health
#   make artillery-anilove

.PHONY: help check \
	validate validate-tf validate-bench validate-fairness validate-aws \
	local-up local-down local-ps local-logs local-rebuild \
	local-test local-test-anilove local-test-csv local-test-thumbnail \
	bench-anilove bench-csv bench-thumbnail \
	bench-down-anilove bench-down-csv bench-down-thumbnail \
	artillery-anilove artillery-csv artillery-thumbnail \
	pilot-anilove pilot-csv pilot-thumbnail pilot-configs \
	loadgen-sync loadgen-pilot-anilove loadgen-pilot-csv loadgen-pilot-thumbnail \
	loadgen-anilove loadgen-csv loadgen-thumbnail \
	artillery-install \
	init plan apply destroy output \
	push-images push-anilove push-csv push-thumbnail \
	lock-deps \
	metrics-proxy sync-targets health \
	ecs-up ecs-down ecs-status

help:
	@echo ""
	@echo "Prereqs / health"
	@echo "  make check             tools + aws credentials"
	@echo "  make validate          validate-tf + validate-bench (local, pre-apply)"
	@echo "  make validate-tf       terraform fmt/validate, backend, tfvars, ECR images"
	@echo "  make validate-bench    artillery + prometheus + compose config"
	@echo "  make validate-aws      post-apply: targets healthy, services, RDS, Lambda"
	@echo "  make validate-fairness only-compute-varies: metrics, pins, deployed specs"
	@echo "  make health            ALB + Lambda /health"
	@echo "  make sync-targets      Artillery YAML from terraform outputs"
	@echo ""
	@echo "Local stack"
	@echo "  make local-up|local-down|local-test|..."
	@echo ""
	@echo "AWS metrics (Docker)"
	@echo "  make bench-anilove|bench-csv|bench-thumbnail"
	@echo "  make metrics-proxy     AniLove EC2/ECS scrape proxy (Node)"
	@echo ""
	@echo "Load tests"
	@echo "  make pilot-anilove|csv|thumbnail   ~7 min service-time probe (run this first)"
	@echo "  make pilot-configs     regenerate pilot-*.yml from test-*.yml"
	@echo "  make artillery-anilove|csv|thumbnail   (from this workstation)"
	@echo ""
	@echo "Load tests from the in-region generator (required for AWS runs)"
	@echo "  make loadgen-sync      stage current suites onto the generator"
	@echo "  make loadgen-pilot-csv|anilove|thumbnail"
	@echo "  make loadgen-csv|anilove|thumbnail"
	@echo ""
	@echo "Terraform"
	@echo "  make init|plan|apply|destroy|output"
	@echo ""
	@echo "Images / ECS capacity"
	@echo "  make lock-deps         pin transitive Python deps (run before push-images)"
	@echo "  make push-images|push-anilove|push-csv|push-thumbnail"
	@echo "  make ecs-up|ecs-down|ecs-status"
	@echo ""

check:
	$(BASH) scripts/check-prereqs.sh

validate: validate-tf validate-bench

validate-tf:
	$(BASH) scripts/validate-terraform.sh

validate-bench:
	$(BASH) scripts/validate-benchmark-config.sh

validate-aws:
	$(BASH) scripts/validate-aws-state.sh

validate-fairness:
	$(BASH) scripts/validate-fairness.sh

health:
	$(BASH) scripts/health-check.sh

sync-targets:
	$(BASH) scripts/sync-artillery-targets.sh
	@# Pilots are generated from test-*.yml and carry its target and Host header.
	$(BASH) scripts/make-pilot-configs.sh

local-up:
	docker compose -f docker-compose.yml up -d --build

local-down:
	docker compose -f docker-compose.yml down

local-ps:
	docker compose -f docker-compose.yml ps

local-logs:
	docker compose -f docker-compose.yml logs -f

local-rebuild:
	docker compose -f docker-compose.yml down -v
	docker compose -f docker-compose.yml up -d --build

artillery-install:
	cd local/artillery && npm install

local-test: artillery-install
	cd local/artillery && npm run test:all

local-test-anilove: artillery-install
	cd local/artillery && npm run test:anilove

local-test-csv: artillery-install
	cd local/artillery && npm run test:csv

local-test-thumbnail: artillery-install
	cd local/artillery && npm run test:thumbnail

bench-anilove:
	cd benchmarks/suites/anilove && docker compose up -d
	@echo "Also run: make metrics-proxy"

bench-csv:
	cd benchmarks/suites/csv-processor && docker compose up -d

bench-thumbnail:
	cd benchmarks/suites/thumbnail-generator && docker compose up -d

bench-down-anilove:
	cd benchmarks/suites/anilove && docker compose down

bench-down-csv:
	cd benchmarks/suites/csv-processor && docker compose down

bench-down-thumbnail:
	cd benchmarks/suites/thumbnail-generator && docker compose down

metrics-proxy:
	node scripts/metrics-proxy.js

pilot-configs:
	$(BASH) scripts/make-pilot-configs.sh

pilot-anilove:
	$(BASH) benchmarks/scripts/run-parallel.sh anilove pilot

pilot-csv:
	$(BASH) benchmarks/scripts/run-parallel.sh csv-processor pilot

pilot-thumbnail:
	$(BASH) benchmarks/scripts/run-parallel.sh thumbnail-generator pilot

loadgen-sync:
	$(BASH) scripts/loadgen-sync.sh

loadgen-pilot-anilove:
	$(BASH) scripts/loadgen-run.sh anilove pilot

loadgen-pilot-csv:
	$(BASH) scripts/loadgen-run.sh csv-processor pilot

loadgen-pilot-thumbnail:
	$(BASH) scripts/loadgen-run.sh thumbnail-generator pilot

loadgen-anilove:
	$(BASH) scripts/loadgen-run.sh anilove

loadgen-csv:
	$(BASH) scripts/loadgen-run.sh csv-processor

loadgen-thumbnail:
	$(BASH) scripts/loadgen-run.sh thumbnail-generator

artillery-anilove:
	$(BASH) benchmarks/scripts/run-parallel.sh anilove

artillery-csv:
	$(BASH) benchmarks/scripts/run-parallel.sh csv-processor

artillery-thumbnail:
	$(BASH) benchmarks/scripts/run-parallel.sh thumbnail-generator

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

destroy:
	cd terraform && terraform destroy -auto-approve

output:
	cd terraform && terraform output

lock-deps:
	$(BASH) scripts/lock-python-deps.sh

push-images:
	$(BASH) scripts/push-ecr.sh all

push-anilove:
	$(BASH) scripts/push-ecr.sh anilove

push-csv:
	$(BASH) scripts/push-ecr.sh csv

push-thumbnail:
	$(BASH) scripts/push-ecr.sh thumbnail

ecs-up:
	$(BASH) scripts/ecs-scale.sh up

ecs-down:
	$(BASH) scripts/ecs-scale.sh down

ecs-status:
	$(BASH) scripts/ecs-scale.sh status
