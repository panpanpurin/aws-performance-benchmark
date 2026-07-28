# Helpers for local stack + Artillery + AWS benchmark suites.
# Needs: Docker Compose, Node/npm (for Artillery). On Windows use Git Bash or WSL for `make`.
#
#   make help
#   make local-up
#   make local-test
#   make bench-anilove
#   make artillery-anilove

.PHONY: help \
	local-up local-down local-ps local-logs local-rebuild \
	local-test local-test-anilove local-test-csv local-test-thumbnail \
	bench-anilove bench-csv bench-thumbnail \
	bench-down-anilove bench-down-csv bench-down-thumbnail \
	artillery-anilove artillery-csv artillery-thumbnail \
	artillery-install

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

help:
	@echo ""
	@echo "Local stack (apps + metrics on your machine)"
	@echo "  make local-up          docker compose up -d --build"
	@echo "  make local-down        docker compose down"
	@echo "  make local-ps          docker compose ps"
	@echo "  make local-logs        follow compose logs"
	@echo "  make local-rebuild     down -v + up --build"
	@echo "  make local-test        Artillery against localhost (all 3 apps)"
	@echo "  make local-test-anilove|csv|thumbnail"
	@echo ""
	@echo "AWS benchmark metrics stacks (can run in parallel; different ports)"
	@echo "  make bench-anilove     :9090 / Grafana :3002 / PG 9092-9094"
	@echo "  make bench-csv         :9190 / Grafana :3102 / PG 9192-9194"
	@echo "  make bench-thumbnail   :9290 / Grafana :3202 / PG 9292-9294"
	@echo "  make bench-down-anilove|csv|thumbnail"
	@echo "  (see benchmarks/docs/PORTS.md)"
	@echo ""
	@echo "Parallel Artillery (EC2+ECS+Lambda within a suite)"
	@echo "  make artillery-anilove   (stack on :9090 / Grafana :3002)"
	@echo "  make artillery-csv       (stack on :9190 / Grafana :3102)"
	@echo "  make artillery-thumbnail (stack on :9290 / Grafana :3202)"
	@echo "  Suites can run together; see benchmarks/docs/PORTS.md"
	@echo ""

# ---------- local ----------

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

# ---------- AWS metrics stacks ----------

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

# ---------- parallel Artillery (shared script) ----------

artillery-anilove:
	bash $(ROOT)benchmarks/scripts/run-parallel.sh anilove

artillery-csv:
	bash $(ROOT)benchmarks/scripts/run-parallel.sh csv-processor

artillery-thumbnail:
	bash $(ROOT)benchmarks/scripts/run-parallel.sh thumbnail-generator
