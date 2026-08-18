SHELL := /bin/bash
.DEFAULT_GOAL := help

DC          := docker compose
PROD_DC     := docker compose -f docker-compose.yml
ENV_FILE    := .env
BACKUP_DIR  := backups
STAMP       := $(shell date +%Y%m%d-%H%M%S)

# Read a value out of .env without sourcing the whole file.
define env_get
$$(grep -E '^$(1)=' $(ENV_FILE) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'')
endef

API_PORT = $(shell grep -E '^API_PORT=' $(ENV_FILE) 2>/dev/null | cut -d= -f2- || echo 8000)
BASE_URL = http://localhost:$(or $(API_PORT),8000)

.PHONY: help
help: ## Show this help
	@echo "Enka — make targets"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  API:   $(BASE_URL)"
	@echo "  Docs:  $(BASE_URL)/docs"

# ---------------------------------------------------------------- setup ----
$(ENV_FILE):
	@cp .env.example $(ENV_FILE)
	@# Replace the placeholders with real random secrets so a fresh clone is
	@# usable — and secure — without hand-editing anything.
	@secret=$$(openssl rand -hex 16); \
	 jwt=$$(openssl rand -hex 32); \
	 pw=$$(openssl rand -hex 16); \
	 sed -i.bak "s|^ENKA_ACCESS_SECRET=.*|ENKA_ACCESS_SECRET=$$secret|; \
	             s|^ENKA_JWT_SECRET=.*|ENKA_JWT_SECRET=$$jwt|; \
	             s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$$pw|" $(ENV_FILE); \
	 rm -f $(ENV_FILE).bak; \
	 echo "Created .env — your access secret is: $$secret"

.PHONY: env
env: $(ENV_FILE) ## Create .env with freshly generated secrets

# ------------------------------------------------------------ lifecycle ----
.PHONY: up
up: $(ENV_FILE) ## Start everything (build if needed)
	$(DC) up -d --build
	@echo "API on $(BASE_URL) — docs at $(BASE_URL)/docs"

.PHONY: down
down: ## Stop everything, keep data
	$(DC) down

.PHONY: down-v
down-v: ## Stop everything and DELETE all data (cards + audio)
	@read -p "This erases the database and every audio file. Type 'yes': " ok; \
	 [ "$$ok" = "yes" ] || { echo "aborted"; exit 1; }
	$(DC) down -v

.PHONY: restart
restart: ## Restart the API container
	$(DC) restart api

.PHONY: rebuild
rebuild: ## Rebuild images from scratch and start
	$(DC) build --no-cache
	$(DC) up -d

.PHONY: prod-up
prod-up: ## Start without the dev override (no reload, no dev deps)
	$(PROD_DC) up -d --build

.PHONY: ps
ps: ## Show container status
	$(DC) ps

.PHONY: logs
logs: ## Tail all logs
	$(DC) logs -f --tail=100

.PHONY: logs-api
logs-api: ## Tail API logs only
	$(DC) logs -f --tail=100 api

# --------------------------------------------------------------- shells ----
.PHONY: shell
shell: ## Shell inside the API container
	$(DC) exec api bash

.PHONY: psql
psql: ## Open psql on the database
	$(DC) exec db psql -U $(call env_get,POSTGRES_USER) -d $(call env_get,POSTGRES_DB)

# ----------------------------------------------------------- migrations ----
.PHONY: migrate
migrate: ## Apply migrations
	$(DC) exec api alembic upgrade head

.PHONY: revision
revision: ## Autogenerate a migration: make revision m="add x"
	@[ -n "$(m)" ] || { echo 'usage: make revision m="describe the change"'; exit 1; }
	$(DC) exec api alembic revision --autogenerate -m "$(m)"

.PHONY: downgrade
downgrade: ## Roll back one migration
	$(DC) exec api alembic downgrade -1

.PHONY: history
history: ## Show migration history
	$(DC) exec api alembic history --indicate-current

# ------------------------------------------------------------- quality ----
.PHONY: test
test: ## Run the test suite
	$(DC) exec -T api pytest -q

.PHONY: lint
lint: ## Check formatting and lint rules
	$(DC) exec -T api ruff check app tests
	$(DC) exec -T api ruff format --check app tests

.PHONY: fmt
fmt: ## Auto-format and fix what can be fixed
	$(DC) exec -T api ruff check --fix app tests
	$(DC) exec -T api ruff format app tests

# ---------------------------------------------------------------- tools ----
.PHONY: token
token: ## Print a fresh JWT (use: TOKEN=$$(make -s token))
	@curl -fsS -X POST $(BASE_URL)/api/v1/auth/token \
		-H 'Content-Type: application/json' \
		-d "{\"secret\":\"$(call env_get,ENKA_ACCESS_SECRET)\"}" \
	 | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'

.PHONY: secret
secret: ## Print the access secret to type into a client
	@echo "$(call env_get,ENKA_ACCESS_SECRET)"

.PHONY: seed
seed: ## Load a handful of demo cards
	$(DC) exec -T api python -m app.seed

.PHONY: stats
stats: ## Print collection stats
	@curl -fsS $(BASE_URL)/api/v1/stats \
		-H "Authorization: Bearer $$($(MAKE) -s token)" | python3 -m json.tool

# --------------------------------------------------------------- backup ----
.PHONY: backup
backup: ## Dump database + audio into backups/
	@mkdir -p $(BACKUP_DIR)
	$(DC) exec -T db pg_dump -U $(call env_get,POSTGRES_USER) -d $(call env_get,POSTGRES_DB) \
		> $(BACKUP_DIR)/enka-$(STAMP).sql
	$(DC) run --rm -T -v "$$PWD/$(BACKUP_DIR):/backup" api \
		tar czf /backup/enka-audio-$(STAMP).tar.gz -C /data audio
	@echo "Wrote $(BACKUP_DIR)/enka-$(STAMP).sql and $(BACKUP_DIR)/enka-audio-$(STAMP).tar.gz"

.PHONY: restore
restore: ## Restore a dump: make restore f=backups/enka-....sql
	@[ -n "$(f)" ] || { echo 'usage: make restore f=backups/enka-20260818-120000.sql'; exit 1; }
	$(DC) exec -T db psql -U $(call env_get,POSTGRES_USER) -d $(call env_get,POSTGRES_DB) < $(f)

# ---------------------------------------------------------------- misc -----
.PHONY: lock
lock: ## Refresh backend/uv.lock after editing pyproject.toml
	cd backend && uv lock

.PHONY: clean
clean: ## Remove local caches
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	rm -rf backend/.pytest_cache backend/.ruff_cache
