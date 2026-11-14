DEV = docker compose -p pilgrim-dev --env-file .env.dev -f docker-compose.yml -f docker-compose.dev.yml

# The Postgres test database lives in the dev Postgres container (port 5433). The harness drops
# and recreates its schema, and refuses database names without "test".
TEST_DB_NAME      ?= pilgrim_test
TEST_DATABASE_URL ?= postgres://pilgrim:pilgrim@127.0.0.1:5433/$(TEST_DB_NAME)?sslmode=disable

# prod, prod-down, deploy and backups come with task I1 (noldam-style docker-compose.prod.yml).
.PHONY: dev dev-down dev-logs test test-db

# Builds the image, applies migrations, starts api (127.0.0.1:3100) and worker.
dev: .env.dev
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
test-db: .env.dev
	$(DEV) up -d --wait postgres
	$(DEV) exec -T postgres sh -c '\
		psql -U "$$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '"'"'$(TEST_DB_NAME)'"'"'" | grep -q 1 \
		|| createdb -U "$$POSTGRES_USER" $(TEST_DB_NAME)'

.env.dev:
	cp .env.dev.example .env.dev
