# KV Store - Design Document

## Architecture Overview

The KV Store is built using Erlang/OTP with three main components:

**1. Cowboy HTTP Server (port 8080)**
- Handles incoming HTTP requests
- Routes requests to the appropriate handler
- Returns JSON responses

**2. KV Store GenServer**
- Stores data in a map: `#{ "key" => "value" }`
- Provides: `set/2`, `get/1`, `delete/1`, `clear_all/0`
- Runs as a supervised process
- Processes requests sequentially (thread-safe)

**3. Supervisor (kv_store_sup)**
- Strategy: `one_for_one`
- Restarts the GenServer and HTTP server on crash
- Provides fault tolerance

### Request Flow

1. Client sends HTTP request (GET, POST, PUT, DELETE) to Cowboy on port 8080
2. Cowboy parses the request and extracts the key and method
3. The handler calls the KV Store GenServer
4. The GenServer updates its internal state (map) and returns the result
5. The response is sent back to the client

### Supervision Tree

- `kv_store_sup` (Supervisor)
  - `kv_store` (GenServer) - Holds the key-value map
  - `kv_http` (Cowboy) - Handles HTTP requests

## Key Design Decisions

### 1. GenServer for State Management

**Why GenServer was chosen:**
- Provides lifecycle management (init, terminate)
- Handles synchronous and asynchronous calls
- Integrates with OTP supervision for fault tolerance
- Simpler than raw `receive` loops or ETS tables for this use case

### 2. Cowboy for HTTP

- Lightweight and production-proven
- Excellent Erlang integration
- Handles HTTP/1.1 and HTTP/2
- Used in many large-scale Erlang/Elixir projects

### 3. Map as Data Structure

- O(1) access time for lookups and inserts
- Immutable: each update returns a new map (ensures thread safety)
- Native Erlang data type with excellent pattern matching support

## API Design

### Endpoints

The endpoint reference -- methods, request bodies, and success and error
status codes -- lives in the [README](README.md#api), which is the single
source of truth for the API surface. This section covers why it is shaped
that way.

### Why Path Parameters?

Path parameters (`/store/mykey`) are more RESTful and cleaner than query strings (`/store?key=mykey`). They follow industry conventions for resource-based APIs.

### Why JSON?

- Ubiquitous and easily consumed by any client
- Supports complex data types (lists, maps, nested structures)
- `jsx` library provides fast, safe encoding/decoding

## Request/Response Examples

### Store a Value

**Request:**
```bash
curl -X POST http://localhost:18080/store \
  -H "Content-Type: application/json" \
  -d '{"key": "user_123", "value": {"name": "João", "score": 42}}'