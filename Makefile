.PHONY: up down fetch load build test docs profile clean results metrics metrics-check charts

up:
	@docker info >/dev/null 2>&1 || (echo "Docker daemon not running - start Docker Desktop or run: colima start" && exit 1)
	docker compose up -d
	@echo "waiting for postgres..."
	@until docker compose exec -T postgres pg_isready -U sec >/dev/null 2>&1; do sleep 1; done
	@echo "ready on port $${POSTGRES_PORT:-5433}"

down:
	docker compose down

fetch:
	python scripts/fetch_sec.py

load:
	python scripts/load_raw.py

build:
	cd dbt && dbt deps && dbt build

test:
	cd dbt && dbt test

docs:
	cd dbt && dbt docs generate && dbt docs serve

profile:
	cd dbt && dbt build --select tag:dq

clean:
	docker compose down -v

results:
	python scripts/export_results.py
	python scripts/export_metrics.py

metrics:
	python scripts/export_metrics.py

metrics-check:
	python scripts/export_metrics.py --check

charts:
	python scripts/make_charts.py
