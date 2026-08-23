# Every target runs inside Docker, so the only thing this needs on the host is
# docker itself -- no Erlang/OTP, no rebar3, no curl. Run `make` for the list.

COMPOSE       ?= docker compose
SERVICE       ?= kv_store
RELEASE_IMAGE ?= kv_store:latest
HOST_PORT     ?= 18080

# Read by docker-compose.yml, so this variable governs the published port as
# well as the messages below.
export HOST_PORT

.DEFAULT_GOAL := help
.PHONY: help build test shell up down logs health release smoke release-run clean

help:
	@echo "make build        Build the dev image"
	@echo "make test         Run the EUnit suite"
	@echo "make shell        Open a rebar3 shell with the app started"
	@echo "make up           Start the service and wait for it to be healthy"
	@echo "make down         Stop the service"
	@echo "make logs         Follow the service logs"
	@echo "make health       Ask the running service for /health"
	@echo "make release      Build the production release image ($(RELEASE_IMAGE))"
	@echo "make smoke        Boot that image and check it serves /health"
	@echo "make release-run  Run that release image in the foreground"
	@echo "make clean        Stop everything and drop images and cached builds"

build:
	$(COMPOSE) build

# Depends on build because `compose run` only builds when the image is
# missing: without it, a Dockerfile or rebar.config change would be silently
# tested against the previous image.
test: build
	$(COMPOSE) run --rm $(SERVICE) rebar3 eunit

# No --service-ports: publishing the service port here fails outright while
# `make up` holds it. Use `make up` when you want the API reachable.
shell: build
	$(COMPOSE) run --rm $(SERVICE) rebar3 shell

# --wait blocks until the healthcheck passes, so the banner is true and a
# following `make health` is not a race.
up:
	$(COMPOSE) up -d --build --wait
	@echo "kv_store listening on http://localhost:$(HOST_PORT)"

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

# Uses the container's own wget rather than a host curl, so the target holds
# to the docker-only promise at the top of this file.
health:
	@$(COMPOSE) exec -T $(SERVICE) wget -qO- http://localhost:8080/health
	@echo ""

# Builds only the runtime stage: the release, without rebar3 or the compiler.
release:
	docker build --target runtime -t $(RELEASE_IMAGE) .
	@$(MAKE) --no-print-directory smoke

# A release can build cleanly and still be unable to boot. The runtime stage
# runs an ERTS compiled against a different base image than it ships on, so a
# musl or OpenSSL soname skew between the two surfaces at startup, not at
# build time -- and nothing else in this file exercises the release. Booting
# it once and asking for /health turns that into a failed build.
smoke:
	-@docker rm -f kv-smoke >/dev/null 2>&1
	@docker run -d --name kv-smoke $(RELEASE_IMAGE) >/dev/null
	@docker exec kv-smoke sh -c 'i=0; until wget -qO- "http://localhost:$$APP_PORT/health"; do i=$$((i+1)); [ $$i -lt 30 ] || exit 1; sleep 1; done' >/dev/null 2>&1 || { echo "smoke: $(RELEASE_IMAGE) did not serve /health"; docker logs kv-smoke 2>&1 | tail -20; docker rm -f kv-smoke >/dev/null 2>&1; exit 1; }
	-@docker rm -f kv-smoke >/dev/null 2>&1
	@echo "smoke: $(RELEASE_IMAGE) booted and served /health"

release-run: release
	docker run --rm -p $(HOST_PORT):8080 $(RELEASE_IMAGE)

# --rmi local is what actually drops the compose-built dev image; `down -v`
# alone removes only containers, networks and volumes.
clean:
	$(COMPOSE) down -v --remove-orphans --rmi local
	-docker image rm -f $(RELEASE_IMAGE)
