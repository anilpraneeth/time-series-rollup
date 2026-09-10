DATABASE_URL ?= postgresql://rollup:rollup@localhost:55432/rollup
export DATABASE_URL

.PHONY: help up down install install-docker demo demo-docker backfill-demo backfill-demo-docker test test-docker shell-check

help:
	@printf '%s\n' \
	  'make up          Start PostgreSQL 16 in Docker' \
	  'make install-docker Install into the empty Docker database' \
	  'make demo-docker Run the repeatable SQL example in Docker' \
	  'make demo        Run the repeatable SQL example (requires psql)' \
	  'make backfill-demo Run a resumable hierarchy backfill example' \
	  'make backfill-demo-docker Run the backfill example in Docker' \
	  'make install     Install into an empty DATABASE_URL (requires psql)' \
	  'make test        Run tests in a disposable local PostgreSQL cluster' \
	  'make test-docker Run tests in a disposable Docker database' \
	  'make down        Stop Docker services, keeping database data' \
	  'make shell-check Check portable shell scripts for syntax errors'

up:
	docker compose up --detach --wait db

install-docker:
	docker compose run --rm bootstrap

demo-docker:
	docker compose run --rm --entrypoint sh bootstrap scripts/demo.sh

down:
	docker compose down

install:
	./scripts/install.sh

demo:
	./scripts/demo.sh

backfill-demo:
	sh scripts/backfill-demo.sh

backfill-demo-docker:
	docker compose run --rm --entrypoint sh bootstrap scripts/backfill-demo.sh

test:
	./scripts/test.sh

test-docker:
	docker compose --profile test run --rm test

shell-check:
	@for script in scripts/*.sh tests/*.sh; do \
	  if [ -f "$$script" ]; then sh -n "$$script" || exit; fi; \
	done
