# KV Store - In-Memory Key-Value HTTP REST Service

[![CI](https://github.com/jonasmigas/erlang-in-memory-rest-service/actions/workflows/ci.yml/badge.svg)](https://github.com/jonasmigas/erlang-in-memory-rest-service/actions/workflows/ci.yml)

A simple in-memory key-value store with a REST API, built in Erlang using OTP and Cowboy.

## Features

- **In-memory storage** in an ETS table owned by a supervised process, no
  external database
- **RESTful HTTP API** over GET, HEAD, POST, PUT and DELETE
- **JSON request/response**, except `/metrics`
- **Reads run in the calling process** and scale across cores; writes are
  serialised so that created-versus-replaced is a single atomic decision
- **Fault-tolerant** under OTP supervision: the listener keeps serving
  while the store restarts, and vice versa
- **Bounded**: a byte ceiling the store refuses to write past, so no
  client can walk the node out of memory
- **Health and metrics endpoints** for monitoring

## Requirements

- Docker, and Docker Compose v2 (the `docker compose` subcommand; the file
  omits the obsolete `version:` key, which Compose v1 cannot parse).
  Everything below runs inside a container, so no local Erlang/OTP or rebar3
  install is needed.
- `make` is optional but assumed by the commands below; each target is a
  one-line docker command you can run directly instead.

## Quick start

Docker is the only requirement. To see the service do what the brief asks:

```bash
make demo      # start it, then walk the brief end to end and show each answer
```

To run the tests, or to start it and poke at it yourself:

```bash
make test      # the EUnit suite, in the same container CI uses
make up        # build and start the service in the background
make health    # confirm it answers
make down      # stop it
```

A passing `make test` prints a few `WARNING REPORT` lines. They are
deliberate: two tests suspend the store and stall a request body on
purpose, and the warnings are the service correctly saying so.

The API is available at `http://localhost:18080` (mapped to 8080 inside the
container).

`make` on its own lists every target:

| Target | What it does |
|--------|--------------|
| `make build` | Build the dev image |
| `make demo` | Walk the brief end to end against a running service |
| `make test` | Run the EUnit suite |
| `make cover` | Run the suite and report line coverage (90% at present) |
| `make dialyzer` | Check the specs in `src/` against the code |
| `make bench` | Compare the ETS read path against a gen_server (see [DESIGN](DESIGN.md#concurrency)) |
| `make bench-http` | Measure requests per second through cowboy (see [DESIGN](DESIGN.md#concurrency)) |
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

All requests and responses are JSON, except `/metrics`, which answers in
the Prometheus text format a scraper already speaks. Ports below assume the non-Docker run
on 8080; under Docker (`make up`) use 18080.

| Method | Endpoint | Request body | Success | Errors |
|--------|----------|--------------|---------|--------|
| `GET` | `/store/:key` | — | `200` `{"key":...,"value":...}` | `404` `key_not_found` |
| `POST` | `/store/:key` | `{"value": ...}` | `201` created / `200` replaced | `400`, `408`, `413`, `507` |
| `POST` | `/store` | `{"key": ..., "value": ...}` | `201` created / `200` replaced | `400`, `408`, `413`, `507` |
| `PUT` | `/store/:key` | `{"value": ...}` | `201` created / `200` replaced | `400`, `408`, `413`, `507` |
| `DELETE` | `/store/:key` | — | `204` | `404` `key_not_found` |
| `GET` | `/health` | — | `200` `{"status":"ok",...}` | `503` `store_unavailable` |
| `GET` | `/metrics` | — | `200` Prometheus text | — |

`HEAD` is accepted wherever `GET` is, and returns the same status with no
body.

A write answers `201` only when it created the key, and that `201` carries
a `Location` naming the path the entry now lives at -- percent-encoded, so
a key with a space or a slash gives a path that resolves. Replacing an
existing key is a `200` and carries no `Location`.

A key has to survive a round trip: the client reads it out of a response
and puts it back in a URL. Two kinds cannot, and both are rejected with
`400` `invalid_key` -- bytes that are not valid UTF-8, which cannot be a
JSON string at all, and the dot segments `.` and `..`, which the router
removes before a key is ever seen. An empty key is rejected the same way.

A body that parses but carries no `value` is `400` `missing_value`,
whether the key came from the path or the body; `invalid_json` means the
body did not parse.

A method the route does not serve returns `405` with an `Allow` header
naming the ones it does -- `/health` serves reads only, and will not
accept a write. A path that matches no route returns `404` `not_found`.

A missing or empty key, or a malformed JSON body, returns `400`. A body
over the size limit returns `413`; one that stops arriving part-way
returns `408`, which is retryable where `413` is not.

The store is bounded, and a write that would take it past `max_bytes`
returns `507` `store_full` -- a different refusal from `413`, which is
about this request being too large. `507` says the request is fine and
there is nowhere to put it, so retrying helps only once something has been
deleted.

The ceiling bounds the table, not the node: request bodies in flight are
outside it, so a node needs `max_bytes` plus `max_connections x 1 MiB`
plus the runtime before it is safely sized -- see
[DESIGN](DESIGN.md#what-the-node-needs-not-what-the-table-holds).

The ceiling defaults to 1 GiB of accounted bytes and should be set from the
memory the node actually has -- `max_bytes` is an application environment
value, so `config/sys.config` or a `-kv_store max_bytes 268435456` VM flag
sets it, the same way the image sets the port. `infinity` turns it off,
which is the behaviour before it existed: a memory leak with an API.
[DESIGN](DESIGN.md#capacity) turns a byte figure into an entry count for a
given value size. If the store itself
cannot be reached, the answer is `503` `store_unavailable` -- the HTTP
listener stays up across a store restart, so this is a state a client can
observe. `/health` answers `503` in that same window rather than `200`,
because a probe that only proves the listener is up proves the one thing
that must already be true for the answer to arrive.

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

### Continuous integration

`.github/workflows/ci.yml` runs on every push to `master` and every pull
request. It calls the same `make` targets a developer calls, so CI uses the
pinned OTP 26 image and its rebar3 rather than a second toolchain installed
beside it that could pass while the real build fails.

| Job | What it guards |
|-----|----------------|
| `make test` | the suite, and `warnings_as_errors` at compile time |
| `make dialyzer` | the specs in `src/`, which are checked rather than decorative |
| `make cover` | line coverage, reported rather than enforced |
| the reverse module order | the suite passes in rebar3's default order because that order happens to be the safe one; this stops a rename quietly reintroducing the fixture bug |
| the bench profile | `bench/` is compiled by no other step, so a harness could rot until a reviewer ran it |
| `make release` | a release that compiles but cannot boot -- the target ends by starting the image and asking it for `/health` |
| commit messages | each commit in a pull request, by running `.githooks/commit-msg` itself rather than restating its rules |

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
