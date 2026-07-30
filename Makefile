# Local stack, Artillery, AWS benchmark suites, and Terraform.
# Needs Docker Compose and Node/npm. On Windows use Git Bash or WSL for make.
#
#   make help
#   make local-up
#   make local-test
#   make bench-anilove
#   make artillery-anilove
#   make destroy

.PHONY: help \
	local-up local-down local-ps local-logs local-rebuild \
	local-test local-test-anilove local-test-csv local-test-thumbnail \
	bench-anilove bench-csv bench-thumbnail \
	bench-down-anilove bench-down-csv bench-down-thumbnail \
	artillery-anilove artillery-csv artillery-thumbnail \
	artillery-install \
	init plan apply destroy output

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TF_DIR := $(ROOT)terraform

help:
	@echo ""
	@echo "Local stack (apps + metrics)"
	@echo "  make local-up          docker compose up -d --build"
	@echo "  make local-down        docker compose down"
	@echo "  make local-ps          docker compose ps"
	@echo "  make local-logs        follow compose logs"
	@echo "  make local-rebuild     down -v + up --build"
	@echo "  make local-test        Artillery against localhost (all 3 apps)"
	@echo "  make local-test-anilove|csv|thumbnail"
	@echo ""
	@echo "AWS metrics stacks (parallel ports; see benchmarks/docs/PORTS.md)"
	@echo "  make bench-anilove     :9090 / Grafana :3002 / PG 9092-9094"
	@echo "  make bench-csv         :9190 / Grafana :3102 / PG 9192-9194"
	@echo "  make bench-thumbnail   :9290 / Grafana :3202 / PG 9292-9294"
	@echo "  make bench-down-anilove|csv|thumbnail"
	@echo ""
	@echo "Parallel Artillery (EC2+ECS+Lambda per suite)"
	@echo "  make artillery-anilove|csv|thumbnail"
	@echo ""
	@echo "Terraform main stack (terraform/; remote state kept in bootstrap)"
	@echo "  make init              terraform init"
	@echo "  make plan              terraform plan"
	@echo "  make apply             terraform apply"
	@echo "  make destroy           destroy ALL main-stack resources (-auto-approve)"
	@echo "  make output            terraform output"
	@echo "  (does not destroy S3/DynamoDB state backend under terraform/bootstrap)"
	@echo ""

local-up:
	docker compose -f $(ROOT)docker-compose.yml up -d --build

local-down:
	docker compose -f $(ROOT)docker-compose.yml down

local-ps:
	docker compose -f $(ROOT)docker-compose.yml ps

local-logs:
	docker compose -f $(ROOT)docker-compose.yml logs -f

local-rebuild:
	docker compose -f $(ROOT)docker-compose.yml down -v
	docker compose -f $(ROOT)docker-compose.yml up -d --build

artillery-install:
	cd $(ROOT)local/artillery && npm install

local-test: artillery-install
	cd $(ROOT)local/artillery && npm run test:all

local-test-anilove: artillery-install
	cd $(ROOT)local/artillery && npm run test:anilove

local-test-csv: artillery-install
	cd $(ROOT)local/artillery && npm run test:csv

local-test-thumbnail: artillery-install
	cd $(ROOT)local/artillery && npm run test:thumbnail

bench-anilove:
	cd $(ROOT)benchmarks/suites/anilove && docker compose up -d

bench-csv:
	cd $(ROOT)benchmarks/suites/csv-processor && docker compose up -d

bench-thumbnail:
	cd $(ROOT)benchmarks/suites/thumbnail-generator && docker compose up -d

bench-down-anilove:
	cd $(ROOT)benchmarks/suites/anilove && docker compose down

bench-down-csv:
	cd $(ROOT)benchmarks/suites/csv-processor && docker compose down

bench-down-thumbnail:
	cd $(ROOT)benchmarks/suites/thumbnail-generator && docker compose down

artillery-anilove:
	bash $(ROOT)benchmarks/scripts/run-parallel.sh anilove

artillery-csv:
	bash $(ROOT)benchmarks/scripts/run-parallel.sh csv-processor

artillery-thumbnail:
	bash $(ROOT)benchmarks/scripts/run-parallel.sh thumbnail-generator

# Terraform main stack only (keeps remote state backend)

init:
	cd $(TF_DIR) && terraform init

plan:
	cd $(TF_DIR) && terraform plan

apply:
	cd $(TF_DIR) && terraform apply

destroy:
	cd $(TF_DIR) && terraform destroy -auto-approve

output:
	cd $(TF_DIR) && terraform output
