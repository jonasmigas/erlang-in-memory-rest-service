# KV Store - In-Memory Key-Value HTTP REST Service

A simple in-memory key-value store with a REST API, built in Erlang using OTP and Cowboy.

## Features

- **In-memory storage** using Erlang maps (no external database)
- **RESTful HTTP API** with GET, POST, PUT, DELETE endpoints
- **JSON request/response** format
- **Concurrent-safe** using GenServer
- **Fault-tolerant** with OTP supervision
- **Health check endpoint** for monitoring

## Requirements

- Docker, and Docker Compose v2 (the `docker compose` subcommand; the file
  omits the obsolete `version:` key, which Compose v1 cannot parse).
  Everything below runs inside a container, so no local Erlang/OTP or rebar3
  install is needed.
- `make` is optional but assumed by the commands below; each target is a
  one-line docker command you can run directly instead.

## Quick start

```bash
make up        # build and start the service in the background
make health    # confirm it answers
make down      # stop it
```

The API is available at `http://localhost:18080` (mapped to 8080 inside the
container).

`make` on its own lists every target:

| Target | What it does |
|--------|--------------|
| `make build` | Build the dev image |
| `make test` | Run the EUnit suite |
| `make shell` | Open a `rebar3 shell` with the app started (no published port, so it works alongside `make up`) |
| `make up` / `make down` | Start the service and wait until it is healthy / stop it |
| `make logs` | Follow the service logs |
| `make health` | Ask the running service for `/health` |
| `make release` | Build the production release image, then smoke-test it |
| `make smoke` | Boot that image and check it serves `/health` |
| `make release-run` | Run that image in the foreground |
| `make clean` | Stop everything, drop images and cached builds |

`src/`, `test/` and `config/` are bind-mounted into the dev container, so an
edit is picked up by the next `make test` or `make shell` without rebuilding.
`_build` lives in a named volume so compiled dependencies survive between
runs -- run `make clean` after changing `rebar.config` to drop stale ones.

## Deployment

`rebar3` builds a relx release, not just a shell target:

```bash
make release      # builds the runtime image, then boots it and checks /health
make release-run  # runs it on http://localhost:18080
```

The runtime image is the release and nothing else -- no rebar3, no compiler,
no sources -- running as a non-root user with a `HEALTHCHECK` on `/health`.
It is roughly 22 MB against roughly 81 MB for the dev image.

Erlang distribution is confined to loopback and the node cookie is generated
per container at first boot, so the release exposes only the HTTP port.

`make release` finishes by booting the image and asking it for `/health`. The
runtime stage runs an ERTS compiled against a different base image than it
ships on, so a library skew between the two would otherwise build cleanly and
fail only at startup -- the one failure nothing else here exercises.

To build a release outside Docker, with Erlang/OTP 26 and rebar3 on the host:

```bash
rebar3 as prod release  # _build/prod/rel/kv_store, ERTS included
rebar3 as prod tar      # the same tree, packaged as a tarball
rebar3 release          # development release under _build/default/rel
rebar3 shell            # REPL with the app started, on port 8080
```

VM flags are in `config/vm.args`. The listen port defaults to
`config/sys.config`, but the runtime image passes `-kv_store port $APP_PORT`,
so `APP_PORT` drives the bind, the `EXPOSE` and the health probe together:

```bash
docker run --rm -e APP_PORT=9099 -p 9099:9099 kv_store:latest
```

On the host side, `HOST_PORT` sets the published port for every make target:

```bash
make up HOST_PORT=19090
```

## API

All requests and responses are JSON. Ports below assume the non-Docker run
on 8080; under Docker (`make up`) use 18080.

| Method | Endpoint | Request body | Success | Errors |
|--------|----------|--------------|---------|--------|
| `GET` | `/store/:key` | — | `200` `{"key":...,"value":...}` | `404` `key_not_found` |
| `POST` | `/store/:key` | `{"value": ...}` | `201` created / `200` replaced | `400`, `408`, `413` |
| `POST` | `/store` | `{"key": ..., "value": ...}` | `201` created / `200` replaced | `400`, `408`, `413` |
| `PUT` | `/store/:key` | `{"value": ...}` | `201` created / `200` replaced | `400`, `408`, `413` |
| `DELETE` | `/store/:key` | — | `204` | `404` `key_not_found` |
| `GET` | `/health` | — | `200` `{"status":"ok",...}` | — |

`HEAD` is accepted wherever `GET` is, and returns the same status with no
body.

A write answers `201` only when it created the key; replacing an existing
one is a `200`, so a client can tell the two apart from the status alone.

A method the route does not serve returns `405` with an `Allow` header
naming the ones it does -- `/health` serves reads only, and will not
accept a write. A path that matches no route returns `404` `not_found`.

A missing or empty key, or a malformed JSON body, returns `400`. A body
over the size limit returns `413`; one that stops arriving part-way
returns `408`, which is retryable where `413` is not. If the store itself
cannot be reached, the answer is `503` `store_unavailable` -- the HTTP
listener stays up across a store restart, so this is a state a client can
observe.

Reading a key that holds no data is always a `404` with an explicit
`key_not_found` error, never an empty `200` -- a client can tell "no data
associated with this key" apart from "this key holds an empty value".

### Examples

```bash
# Store a value
curl -X POST http://localhost:8080/store/user_123   -H 'Content-Type: application/json'   -d '{"value": {"name": "Ana", "score": 42}}'

# Retrieve it -- returns both the key and the data
curl http://localhost:8080/store/user_123
# {"key":"user_123","value":{"name":"Ana","score":42}}

# Clear it
curl -X DELETE http://localhost:8080/store/user_123

# Subsequent reads report the key as unset
curl -i http://localhost:8080/store/user_123
# HTTP/1.1 404 Not Found
# {"error":"key_not_found","key":"user_123"}
```

## Development

### Running the tests

```bash
make test
```

Equivalent to `docker compose run --rm kv_store rebar3 eunit`, or plain
`rebar3 eunit` if you have rebar3 on the host.

### Commit hooks

Commit conventions are enforced by git hooks in `.githooks/`. Git does not
enable a repo's hooks automatically, so turn them on once per clone:

```bash
git config core.hooksPath .githooks
```

- `commit-msg` **rejects** a message that does not follow
  `type(scope): title`, a blank line, then a description body. The title
  must be lowercase and imperative with no trailing period; subjects over
  72 characters are rejected and over 50 are warned about.
- `pre-commit` **warns** when files under `src/` are staged without any
  file under `test/`, as a reminder that behaviour changes belong with
  their tests.
