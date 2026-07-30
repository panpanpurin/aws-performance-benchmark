# Run from repo root. Scripts are bash (.sh) + Node.
# On Windows: Git Bash, WSL, or bash on PATH.
#
#   make help
#   make check
#   make apply
#   make push-images
#   make sync-targets
#   make health
#   make artillery-anilove

.PHONY: help check \
	local-up local-down local-ps local-logs local-rebuild \
	local-test local-test-anilove local-test-csv local-test-thumbnail \
	bench-anilove bench-csv bench-thumbnail \
	bench-down-anilove bench-down-csv bench-down-thumbnail \
	artillery-anilove artillery-csv artillery-thumbnail \
	artillery-install \
	init plan apply destroy output \
	push-images push-anilove push-csv push-thumbnail \
	metrics-proxy sync-targets health \
	ecs-up ecs-down ecs-status

help:
	@echo ""
	@echo "Prereqs / health"
	@echo "  make check             tools + aws credentials"
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
	@echo "  make artillery-anilove|csv|thumbnail"
	@echo ""
	@echo "Terraform"
	@echo "  make init|plan|apply|destroy|output"
	@echo ""
	@echo "Images / ECS capacity"
	@echo "  make push-images|push-anilove|push-csv|push-thumbnail"
	@echo "  make ecs-up|ecs-down|ecs-status"
	@echo ""

check:
	bash scripts/check-prereqs.sh

health:
	bash scripts/health-check.sh

sync-targets:
	bash scripts/sync-artillery-targets.sh

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
	node scripts/anilove-metrics-proxy.js

artillery-anilove:
	bash benchmarks/scripts/run-parallel.sh anilove

artillery-csv:
	bash benchmarks/scripts/run-parallel.sh csv-processor

artillery-thumbnail:
	bash benchmarks/scripts/run-parallel.sh thumbnail-generator

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

push-images:
	bash scripts/push-ecr.sh all

push-anilove:
	bash scripts/push-ecr.sh anilove

push-csv:
	bash scripts/push-ecr.sh csv

push-thumbnail:
	bash scripts/push-ecr.sh thumbnail

ecs-up:
	bash scripts/ecs-scale.sh up

ecs-down:
	bash scripts/ecs-scale.sh down

ecs-status:
	bash scripts/ecs-scale.sh status
