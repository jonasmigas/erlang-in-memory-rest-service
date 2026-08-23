# Every target runs inside Docker, so the only thing this needs on the host is
# docker itself -- no Erlang/OTP, no rebar3. Run `make` for the target list.

COMPOSE       ?= docker compose
SERVICE       ?= kv_store
RELEASE_IMAGE ?= kv_store:latest
HOST_PORT     ?= 18080

# Git Bash rewrites arguments that look like unix paths before handing them to
# docker.exe, which mangles container-side paths. Harmless elsewhere.
export MSYS_NO_PATHCONV = 1

.DEFAULT_GOAL := help
.PHONY: help build test shell up down logs health release release-run clean

help:
	@echo "make build        Build the dev image"
	@echo "make test         Run the EUnit suite"
	@echo "make shell        Open a rebar3 shell with the app started"
	@echo "make up           Start the service in the background"
	@echo "make down         Stop the service"
	@echo "make logs         Follow the service logs"
	@echo "make health       Curl /health on the running service"
	@echo "make release      Build the production release image ($(RELEASE_IMAGE))"
	@echo "make release-run  Run that release image in the foreground"
	@echo "make clean        Stop everything and drop images and cached builds"

build:
	$(COMPOSE) build

# --rm so one-off test runs do not leave stopped containers behind.
test:
	$(COMPOSE) run --rm $(SERVICE) rebar3 eunit

# --service-ports publishes 18080 for the throwaway container the shell runs in.
shell:
	$(COMPOSE) run --rm --service-ports $(SERVICE) rebar3 shell

up:
	$(COMPOSE) up -d --build
	@echo "kv_store listening on http://localhost:$(HOST_PORT)"

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

health:
	curl -fsS http://localhost:$(HOST_PORT)/health && echo ""

# Builds only the runtime stage: the release, without rebar3 or the compiler.
release:
	docker build --target runtime -t $(RELEASE_IMAGE) .

release-run:
	docker run --rm -p $(HOST_PORT):8080 $(RELEASE_IMAGE)

clean:
	$(COMPOSE) down -v --remove-orphans
	-docker image rm -f $(RELEASE_IMAGE)
