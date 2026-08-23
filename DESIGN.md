# KV Store - Design Document

## Architecture Overview

The KV Store is built using Erlang/OTP with three main components:

**1. Cowboy HTTP Server (port 8080)**
- Handles incoming HTTP requests
- Routes requests to the appropriate handler
- Returns JSON responses

**2. KV Store GenServer**
- Owns an ETS table holding the data: `{Key, Value}`, keys are binaries
- Provides: `set/2`, `get/1`, `delete/1`, `clear_all/0`, `get_all/0`
- Runs as a supervised process
- Serialises writes; reads run in the caller (see Concurrency below)

**3. Supervisor (kv_store_sup)**
- Strategy: `one_for_one`
- Restarts the GenServer and HTTP server on crash
- Provides fault tolerance

### Request Flow

1. Client sends HTTP request (GET, POST, PUT, DELETE) to Cowboy on port 8080
2. Cowboy parses the request and extracts the key and method
3. Reads look the key up in the ETS table directly; writes call the GenServer
4. The GenServer applies the write and reports whether it created or replaced
5. The response is sent back to the client

### Supervision Tree

- `kv_store_sup` (Supervisor)
  - `kv_store` (GenServer) - owns the ETS table
  - `kv_http` (Cowboy) - Handles HTTP requests

`one_for_one` is deliberate: the listener keeps serving while the store
restarts, and the store keeps its data while the listener restarts. The
cost is stated plainly under Durability.

## Key Design Decisions

### 1. GenServer for writes

**Why a GenServer still owns writes:**
- Lifecycle management (init, terminate) and OTP supervision
- Serialising writes is what makes created-vs-updated a single atomic
  decision: `ets:insert_new/2` answers it in the same operation that
  performs the write, so the HTTP layer can return 201 or 200 without a
  read-then-write across two calls that another writer could interleave

### 2. Cowboy for HTTP

- Lightweight and production-proven
- Excellent Erlang integration
- Handles HTTP/1.1 and HTTP/2
- Used in many large-scale Erlang/Elixir projects

### 3. ETS for the data, read outside the process

The store began as a map held in the GenServer's state. That is the
simplest thing that works, and for a single client it is fine. It has one
property that does not survive contact with a real workload: every read
was a message to one process and a wait for its reply, so reads queued
behind each other and behind every write.

The data now lives in an ETS table the GenServer owns — `protected`, so
that process is still the only writer, with `read_concurrency` because
reads are the point. `get/1` and `get_all/0` run in the calling process.

See Concurrency for what this is and is not measured to fix.

## Concurrency

### The architectural reason

A `gen_server` handles one message at a time. That is its value for
writes — it is why created-vs-updated is atomic here — and it is a
liability for reads. Every read paid for a place in a queue it had no
reason to be in, sharing that queue with writes and with every other
reader. One slow caller delayed all of them; a busy store turned reads
into timeouts. For a store whose whole job is reading, the serialisation
point sat on the wrong operation.

ETS reads do not go through a process, so they neither queue nor block
each other, and `read_concurrency` lets them run on multiple schedulers.

### What is measured

Reads survive a store that is wedged. `kv_http_tests` suspends the
GenServer with `sys:suspend/1` and asserts that reads keep answering
`200` while writes report `503 store_unavailable`. Before this change
every verb timed out. `kv_store_tests` covers the other end: with no
store running at all, `get/1` returns `{error, unavailable}` rather than
crashing its caller.

Correctness under load: 300 concurrent writes followed by 300 concurrent
reads return 300/300 correct values, no 5xx.

### What is not measured, and why

The throughput argument — that reads should now use more than one core —
is the usual reason for this change and is very likely true. It is not
claimed here as a number.

Benchmarking was attempted on Docker Desktop for Windows and abandoned:
identical configurations varied roughly threefold between runs (one
measurement of the same read loop ranged from 65k to 197k ops/s). Nothing
honest can be concluded from differences smaller than that spread. A
figure would need a quiet Linux host and a load generator that is not
spawning a process per request.

### What this does not fix

A large value is still copied to whoever reads it. Moving the read out of
the GenServer moved where the copy happens, not whether it happens: one
client pulling a multi-megabyte entry still consumes CPU and allocator
bandwidth that every other request needs. Measured on this setup, small-key
reads degraded by a similar proportion with and without the change.

If that mattered, the fix is not more concurrency — it is not storing
values large enough to care about, or handing back a reference rather than
a copy.

### Durability

There is none, by design: the brief asks for an in-memory store. The table
is owned by the GenServer, so it dies with it. Under `one_for_one` the
supervisor restarts the store and **every key is gone**, while the listener
keeps answering `200` on `/health` as though nothing happened. That is the
right trade for the brief and the wrong one for anything that must not lose
data; persistence would be the next design decision, not a tuning exercise.

## API Design

### Endpoints

The endpoint reference -- methods, request bodies, and success and error
status codes -- lives in the [README](README.md#api), which is the single
source of truth for the API surface. This section covers why it is shaped
that way.

### Why Path Parameters?

Path parameters (`/store/mykey`) are more RESTful and cleaner than query strings (`/store?key=mykey`). They follow industry conventions for resource-based APIs.

A key has to survive that round trip: the client reads it out of a
response and puts it back in a URL. Keys that cannot — bytes that are not
valid UTF-8, and the dot segments the router removes — are refused with
`400 invalid_key` rather than stored somewhere unreachable.

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
```

**Response:** `201 Created`, with `Location` naming where it landed.

```text
location: /store/user_123

{"status":"stored","value":{"name":"João","score":42},"key":"user_123"}
```

Repeating the same request replaces the value and answers `200 OK` with no
`Location`, so a client can tell a create from an update by the status.

### Read It Back

**Request:**
```bash
curl http://localhost:18080/store/user_123
```

**Response:** `200 OK`

```json
{"value":{"name":"João","score":42},"key":"user_123"}
```

### Clear It

**Request:**
```bash
curl -X DELETE http://localhost:18080/store/user_123
```

**Response:** `204 No Content`. A subsequent read is `404` with an explicit
`key_not_found`, identical to a key that was never written — the brief
requires those two to be indistinguishable.
