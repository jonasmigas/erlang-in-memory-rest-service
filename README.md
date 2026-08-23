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

- Docker and Docker Compose (recommended — no local Erlang install needed)
- Or, to run without Docker: Erlang/OTP 22+ and Rebar3

## Quick Start (Docker)

```bash
docker-compose up --build
```

The API is available at `http://localhost:18080` (mapped to port 8080 inside the container).

## Quick Start (without Docker)

```bash
# Clone the repository
git clone <your-repo-url>
cd kv_store

# Compile
rebar3 compile

# Run tests
rebar3 eunit

# Start the application (this also starts the HTTP server automatically)
rebar3 shell
```

The API is now available at `http://localhost:8080`.

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
rebar3 eunit
```

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
