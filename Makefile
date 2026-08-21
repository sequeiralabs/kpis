# Program KPI database — convenience targets.
# Requires Docker. psql is used from inside the container, so no local client needed.

DC   := docker compose
PSQL := $(DC) exec -T db psql -U kpi -d kpi -v ON_ERROR_STOP=1

.DEFAULT_GOAL := help
.PHONY: help up down reset logs psql test verify dashboard schema-docs scorecard quality lineage dump

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Start the database and Adminer, loading the schema on first run
	$(DC) up -d
	@echo "waiting for the schema and demo data to load (first run takes ~2 minutes)..."
	@until $(DC) exec -T db psql -U kpi -d kpi -tAc \
	    "select count(*) from kpi.observation" >/dev/null 2>&1; do sleep 3; done
	@echo "ready."
	@echo "  Adminer   http://localhost:8080  (server db, user kpi, password kpi, database kpi)"
	@echo "  Dashboard http://localhost:8081"

down: ## Stop the containers, keeping the data
	$(DC) down

reset: ## Destroy the data volume and rebuild from schema/
	$(DC) down -v
	$(MAKE) up

logs: ## Follow the database log
	$(DC) logs -f db

psql: ## Open an interactive psql session
	$(DC) exec db psql -U kpi -d kpi

test: ## Run the smoke test (rolls back; leaves the database unchanged)
	@$(PSQL) -q -f - < tests/smoke_test.sql 2>&1 | sed 's/^psql:[^ ]*: //'

verify: ## Assert the demo data loaded as expected
	@$(PSQL) -q -f - < tests/verify_demo.sql 2>&1 | sed 's/^psql:[^ ]*: //'

dashboard: ## Re-export dashboard data from the database and rebuild the SPA
	@$(DC) exec -T db psql -U kpi -d kpi -tAqX -f - < tools/export_dashboard.sql > dashboard/data.json
	@python3 tools/build_dashboard.py
	@echo "open http://localhost:8081"

schema-docs: ## Regenerate docs/Schema-Reference.md from the live database
	@$(DC) exec -T db psql -U kpi -d kpi -tAqX -f - < tools/schema_introspect.sql > build/schema.json
	@python3 tools/build_schema_docs.py build/schema.json

scorecard: ## Print the FY2025 institutional scorecard
	@$(PSQL) -P pager=off -c "select category_name, kpi_code, kpi_name, value, target_value, \
	  achievement_pct, performance_band from kpi.v_institution_scorecard_display d \
	  join kpi.reporting_period rp on rp.id = d.reporting_period_id \
	  where rp.code = 'FY2025' order by category_order, kpi_code;"

quality: ## Print the data-quality summary across the seven dimensions
	@$(PSQL) -P pager=off -c "select * from kpi.v_dq_dimension_summary order by dimension;"

lineage: ## Trace one KPI back to its source observations
	@$(PSQL) -P pager=off -c "select program_name, project_name, activity_name, \
	  disaggregation_key, numerator, denominator, status from kpi.v_kpi_lineage \
	  where indicator_code = 'KPI_6' limit 20;"

dump: ## Write a plain-SQL dump to build/kpi_dump.sql
	@mkdir -p build
	@$(DC) exec -T db pg_dump -U kpi -d kpi > build/kpi_dump.sql
	@echo "wrote build/kpi_dump.sql"
