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
.PHONY: help build test bench shell up down logs health release smoke release-run clean

help:
	@echo "make build        Build the dev image"
	@echo "make test         Run the EUnit suite"
	@echo "make bench        Compare the ETS read path against a gen_server"
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

# Compares reading from ETS against reading through a gen_server, both in
# one VM and alternating, so host noise lands on both. Not part of `make
# test`: it takes a while and it measures, it does not assert.
bench: build
	$(COMPOSE) run --rm $(SERVICE) sh -c 'rebar3 as bench compile && erl -pa _build/bench/lib/kv_store/ebin _build/bench/lib/kv_store/bench _build/bench/lib/*/ebin -noshell -eval "kv_bench:main(), halt()."'

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
	@$(COMPOSE) exec -T $(SERVICE) wget -qO- http://127.0.0.1:8080/health
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
#
# The retry loop sits out here rather than inside a single docker exec. If
# the container is not accepting exec yet when the probe fires, one exec
# fails and takes the whole check with it -- a container that was merely
# slow to start would be reported as a release that cannot boot. Retrying
# the exec itself makes not-ready-yet indistinguishable from not-serving-yet,
# which is what this wants.
smoke:
	-@docker rm -f kv-smoke >/dev/null 2>&1
	@docker run -d --name kv-smoke $(RELEASE_IMAGE) >/dev/null
	@ok=0; \
	for i in $$(seq 1 30); do \
	    if docker exec kv-smoke sh -c 'wget -qO- "http://127.0.0.1:$$APP_PORT/health"' >/dev/null 2>&1; then \
	        ok=1; break; \
	    fi; \
	    if [ -z "$$(docker ps -q -f name=kv-smoke)" ]; then \
	        echo "smoke: container exited before it served anything"; break; \
	    fi; \
	    sleep 1; \
	done; \
	if [ $$ok -eq 1 ]; then \
	    echo "smoke: $(RELEASE_IMAGE) booted and served /health"; \
	else \
	    echo "smoke: $(RELEASE_IMAGE) did not serve /health; its output follows"; \
	    docker logs kv-smoke 2>&1 | tail -30; \
	fi; \
	docker rm -f kv-smoke >/dev/null 2>&1; \
	[ $$ok -eq 1 ]

release-run: release
	docker run --rm -p $(HOST_PORT):8080 $(RELEASE_IMAGE)

# --rmi local is what actually drops the compose-built dev image; `down -v`
# alone removes only containers, networks and volumes.
clean:
	$(COMPOSE) down -v --remove-orphans --rmi local
	-docker image rm -f $(RELEASE_IMAGE)
