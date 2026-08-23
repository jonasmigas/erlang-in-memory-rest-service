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
