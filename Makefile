LOG_FILE=supabase_setup.log
TIMESTAMP=$(shell date +"%Y-%m-%d %H:%M:%S")

# Supabase CLI entry point. `yarn supabase` is routed through scripts/supabase.mjs,
# which picks the right binary per platform. This matters on Windows: the npm
# `supabase` package only ships `bin/supabase.exe`, while its package.json `bin`
# field points at `bin/supabase`, so Yarn's binary resolution fails there.
# Override if needed: `make run-dev SUPABASE="npx supabase"`.
SUPABASE ?= yarn supabase

init-log:
	@echo "[$(TIMESTAMP)] Initializing setup process" | tee $(LOG_FILE)
	@if [ ! -f supabase/config.toml ]; then \
		echo "[$(TIMESTAMP)] Error: Supabase not initialized. Run 'yarn supabase init' first." | tee -a $(LOG_FILE); \
		exit 1; \
	fi
	@echo "[$(TIMESTAMP)] Supabase config found, proceeding with setup" | tee -a $(LOG_FILE)

setup-supabase: init-log
	@echo "[$(TIMESTAMP)] Starting Supabase setup..." | tee -a $(LOG_FILE)
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "[$(TIMESTAMP)] Error: Docker is not installed or not running." | tee -a $(LOG_FILE); \
		exit 1; \
	fi
	@echo "[$(TIMESTAMP)] Docker is running, executing 'yarn supabase start'..." | tee -a $(LOG_FILE)
	@rm -f .env
	@if $(SUPABASE) start > supabase_output.txt 2>> $(LOG_FILE); then \
		echo "[$(TIMESTAMP)] Supabase started successfully" | tee -a $(LOG_FILE); \
	else \
		echo "[$(TIMESTAMP)] Error: Failed to start Supabase. Check $(LOG_FILE) for details." | tee -a $(LOG_FILE); \
		exit 1; \
	fi
	@echo "[$(TIMESTAMP)] Creating .env file with Supabase configurations..." | tee -a $(LOG_FILE)
	@if [ -s supabase_output.txt ]; then \
		supabase_url="$$(grep 'Project URL' supabase_output.txt | grep -Eo 'http://[a-zA-Z0-9.:]+' | head -1)"; \
		echo "NEXT_PUBLIC_SUPABASE_TOKEN=127" >> .env; \
		echo "NEXT_PUBLIC_DESTINATION=/auth/sign-in" >> .env; \
		echo "NEXT_PUBLIC_APP_URL=http://localhost:3000" >> .env; \
		echo "NEXT_IMAGE_PUBLIC_URL=$$supabase_url/storage/**" >> .env; \
		echo "NEXT_PUBLIC_SUPABASE_URL=$$supabase_url" >> .env; \
		echo "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=$$(grep 'Publishable' supabase_output.txt | grep -Eo 'sb_publishable_[a-zA-Z0-9_-]+' | head -1)" >> .env; \
		echo "SUPABASE_SECRET_KEY=$$(grep 'Secret' supabase_output.txt | grep -Eo 'sb_secret_[a-zA-Z0-9_-]+' | head -1)" >> .env; \
		echo "NEXT_PUBLIC_SUPABASE_DB_URL=$$(grep 'postgresql://' supabase_output.txt | grep -Eo 'postgresql://[a-zA-Z0-9.:@/-]+' | head -1)" >> .env; \
		echo "[$(TIMESTAMP)] .env file created successfully" | tee -a $(LOG_FILE); \
	else \
		echo "[$(TIMESTAMP)] Error: Supabase output is empty. Check Supabase CLI or Docker setup." | tee -a $(LOG_FILE); \
		rm -f supabase_output.txt; \
		exit 1; \
	fi
	@rm -f supabase_output.txt
	@echo "[$(TIMESTAMP)] Temporary output file cleaned up" | tee -a $(LOG_FILE)

# Default dev loop: the app against the Supabase cloud project (pushcart-dev), no Docker.
# .env.cloud holds the cloud URL/keys; it is copied over .env, which `make setup-supabase`
# regenerates for the local Docker stack when you switch back.
dev:
	@if [ ! -f .env.cloud ]; then \
		echo "Error: .env.cloud not found. Ask a teammate for it (it holds the cloud keys)."; \
		exit 1; \
	fi
	@cp .env.cloud .env
	@echo "Using Supabase cloud (pushcart-dev)"
	yarn dev

# Local Docker stack instead of the cloud. Use it to try migrations or run the e2e
# scripts before they touch the shared cloud database.
dev-local: setup-supabase
	yarn dev

# Apply new migrations in supabase/migrations to the cloud project. Requires
# `yarn supabase login` (run in a real terminal) and `yarn supabase link --project-ref ssitglvklxcdxmgpeoti`.
cloud-push:
	$(SUPABASE) db push

# Push the [auth] settings in supabase/config.toml (anonymous sign-ins, confirmations) to the cloud.
cloud-config-push:
	$(SUPABASE) config push

# Load supabase/seeds into the cloud project. The CLI records the seed file's hash, so it
# only runs again after the seed changes; the seed itself is idempotent either way.
cloud-seed:
	$(SUPABASE) db push --include-seed

# Create or reset the admin and cashier accounts and the POS staff PIN, against whichever
# project .env points at. Passwords come from SEED_* in .env (see scripts/seed-accounts.mjs).
seed-accounts:
	node scripts/seed-accounts.mjs

run-dev:
	$(SUPABASE) start --ignore-health-check
	yarn dev
	@echo "running dev with supabase"

run-start:
	$(SUPABASE) start --ignore-health-check
	yarn start
	@echo "Running prod with supabase"

start-app:
	yarn start
	@echo "Starting the app"

build-app:
	yarn lint
	yarn build
	@echo "Finish checking linter and building"

stop-db:
	@$(SUPABASE) stop
	@echo "stopping supabase db"

cleanup-anonymous:
	@yarn cleanup:anonymous
	@echo "cleaning up anonymous customer users"

clean:
	@echo "[$(TIMESTAMP)] Stopping Supabase and cleaning up..." | tee -a $(LOG_FILE)
	@if $(SUPABASE) stop >> $(LOG_FILE) 2>&1; then \
		echo "[$(TIMESTAMP)] Supabase stopped successfully" | tee -a $(LOG_FILE); \
	else \
		echo "[$(TIMESTAMP)] Warning: Failed to stop Supabase. Check $(LOG_FILE) for details." | tee -a $(LOG_FILE); \
	fi
	@rm -f .env
	@echo "[$(TIMESTAMP)] .env file removed" | tee -a $(LOG_FILE)

migrate-new:
	@$(SUPABASE) migration new $(name)

migrate-up:
	@$(SUPABASE) migration up

migrate-diff:
	@$(SUPABASE) db diff --local > supabase/migrations/$(shell date +%Y%m%d%H%M%S)_schema_changes.sql

migrate-reset:
	@$(SUPABASE) db reset

generate-types:
	$(SUPABASE) gen types typescript --local

.PHONY: all init-log setup-supabase clean migrate-new migrate-up migrate-diff migrate-reset \
	stop-db cleanup-anonymous dev dev-local cloud-push cloud-config-push cloud-seed seed-accounts \
	run-dev run-start \
	start-app build-app generate-types
