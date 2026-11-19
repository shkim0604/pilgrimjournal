DEV  = docker compose -p pilgrim-dev --env-file .env.dev -f docker-compose.yml -f docker-compose.dev.yml
PROD = docker compose -p pilgrim-prod --env-file .env.prod -f docker-compose.yml -f docker-compose.prod.yml

# The Postgres test database lives in the dev Postgres container (port 5433). The harness drops
# and recreates its schema, and refuses database names without "test".
TEST_DB_NAME      ?= pilgrim_test
TEST_DATABASE_URL ?= postgres://pilgrim:pilgrim@127.0.0.1:5433/$(TEST_DB_NAME)?sslmode=disable

# Shared with the admin console (web/admin/docker-compose.yml); see docker-compose.yml.
EDGE_NETWORK = pilgrim-edge

# Prod host: the Mac mini, reached through the `delight` entry in ~/.ssh/config. DEPLOY_DIR is a
# plain folder (not a git checkout, not under ~/Documents): rsync --delete owns it, apart from the
# .env.* files that live only there.
DEPLOY_HOST       ?= delight
DEPLOY_DIR        ?= Developments/pilgrim-server
# Public check after the loopback one. Empty skips it (before the tunnel path rule exists).
DEPLOY_HEALTH_URL ?= https://pilgrim.delight-house.org/api/health
LOCAL_HEALTH_URL  ?= http://127.0.0.1:3100/api/health
# Non-interactive ssh gets a bare PATH without Homebrew or Docker Desktop.
REMOTE_PATH = /opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin
APP_VERSION ?= $(shell git describe --always --dirty --exclude '*' 2>/dev/null || echo unknown)

# Backups (prod host): restic → iCloud Drive (or R2). Settings and secrets live outside the repo in
# BACKUP_ENV_FILE (template: scripts/backup.env.example).
BACKUP_DIR      ?= $(HOME)/backups/pilgrim
BACKUP_ENV_FILE ?= $(HOME)/.config/pilgrim-backup/env
BACKUP_LABEL    = com.dhouse.pilgrim.backup
BACKUP_PLIST    = $(HOME)/Library/LaunchAgents/$(BACKUP_LABEL).plist

.PHONY: dev dev-down dev-logs test test-db edge-network \
	prod prod-down prod-logs prod-ps health deploy \
	backup backup-init backup-snapshots backup-schedule backup-unschedule restore

# ---- development (dev Mac) ------------------------------------------------------------------

# Builds the image, applies migrations, starts api (127.0.0.1:3100) and worker.
dev: .env.dev edge-network
	$(DEV) up -d --build
	@echo "api: http://127.0.0.1:3100/api/health"

dev-down:
	$(DEV) down

dev-logs:
	$(DEV) logs -f api worker

# Contract tests, then the server tests against Postgres in Docker.
test: test-db
	swift test --package-path PilgrimAPI
	TEST_DATABASE_URL='$(TEST_DATABASE_URL)' swift test

# Starts only the dev Postgres and makes sure the test database exists.
test-db: .env.dev edge-network
	$(DEV) up -d --wait postgres
	$(DEV) exec -T postgres sh -c '\
		psql -U "$$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '"'"'$(TEST_DB_NAME)'"'"'" | grep -q 1 \
		|| createdb -U "$$POSTGRES_USER" $(TEST_DB_NAME)'

# Idempotent: creates the shared network only when it is missing.
edge-network:
	@docker network inspect $(EDGE_NETWORK) >/dev/null 2>&1 || docker network create $(EDGE_NETWORK) >/dev/null
	@echo "network $(EDGE_NETWORK) ready"

# ---- production (Mac mini) ------------------------------------------------------------------

# Builds the image, applies migrations with it (stops here if they fail, leaving the old api
# running), then always recreates api and worker: compose has kept an old container running after
# a fresh build on the Mac mini. Postgres is started but never recreated.
prod: .env.prod edge-network
	$(PROD) up -d --wait postgres
	$(PROD) build api
	$(PROD) run --rm --no-deps migrate
	APP_VERSION='$(APP_VERSION)' $(PROD) up -d --no-build --no-deps --force-recreate api worker
	@echo "api: $(LOCAL_HEALTH_URL)"

prod-down:
	$(PROD) down

prod-logs:
	$(PROD) logs -f api worker

prod-ps:
	$(PROD) ps -a

# Waits for the loopback health check (run on the host that runs the server).
health:
	curl -fsS --retry 30 --retry-delay 2 --retry-all-errors $(LOCAL_HEALTH_URL) && echo

# Run from the dev Mac: copies server/ to the Mac mini, rebuilds there, then waits for
# /api/health on the Mac mini's loopback and (when DEPLOY_HEALTH_URL is set) through the tunnel.
# .env.* files on either side are never copied or deleted.
deploy:
	rsync -az --delete \
		--exclude .build --exclude .swiftpm --exclude .media --exclude .DS_Store \
		--include '.env.*.example' --exclude '.env.*' \
		./ $(DEPLOY_HOST):$(DEPLOY_DIR)/
	ssh $(DEPLOY_HOST) 'cd $(DEPLOY_DIR) && PATH=$(REMOTE_PATH) make prod health APP_VERSION=$(APP_VERSION)'
	@if [ -n "$(DEPLOY_HEALTH_URL)" ]; then \
		curl -fsS --retry 15 --retry-delay 2 --retry-all-errors $(DEPLOY_HEALTH_URL) && echo; \
	fi

# ---- backups (Mac mini) ---------------------------------------------------------------------

# One backup now: pg_dump + photo volume → restic, then 7-day retention.
backup:
	BACKUP_DIR='$(BACKUP_DIR)' BACKUP_ENV_FILE='$(BACKUP_ENV_FILE)' ./scripts/backup.sh

# Creates the restic repository once (no-op when it exists).
backup-init:
	BACKUP_ENV_FILE='$(BACKUP_ENV_FILE)' ./scripts/backup.sh --init

backup-snapshots:
	BACKUP_ENV_FILE='$(BACKUP_ENV_FILE)' ./scripts/backup.sh --list

# Installs (or reinstalls) the daily 04:00 launchd job for the logged-in user.
backup-schedule:
	BACKUP_DIR='$(BACKUP_DIR)' BACKUP_ENV_FILE='$(BACKUP_ENV_FILE)' ./scripts/install-backup-schedule.sh

backup-unschedule:
	./scripts/install-backup-schedule.sh --uninstall

# Restores a snapshot. Examples (scripts/restore.sh --help):
#   make restore ARGS='--into dev'                   latest snapshot into the local dev stack
#   make restore ARGS='--into prod --confirm pilgrim-prod --snapshot 1a2b3c4d'
restore:
	BACKUP_DIR='$(BACKUP_DIR)' BACKUP_ENV_FILE='$(BACKUP_ENV_FILE)' ./scripts/restore.sh $(ARGS)

.env.dev:
	cp .env.dev.example .env.dev

.env.prod:
	@echo "Missing server/.env.prod. Copy .env.prod.example and fill in real values." && exit 1
