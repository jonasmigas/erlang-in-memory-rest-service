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
