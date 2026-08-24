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
2. Cowboy matches a route and names it: the store, the health check, or
   neither -- an unmatched path is answered by the handler as a JSON 404
   rather than by the router as an empty one
3. Reads look the key up in the ETS table directly; writes call the GenServer
4. The GenServer applies the write and reports whether it created or replaced
5. The response is sent back to the client

### Supervision Tree

- `kv_store_sup` (Supervisor)
  - `kv_store` (GenServer) - owns the ETS table holding the data
  - `kv_metrics` (GenServer) - owns the counter table, started before the
    listener so the table exists by the time a request can arrive
  - `kv_http` (Cowboy) - handles HTTP requests

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

ETS is the expected answer for an in-memory store in Erlang, so the choice
itself is not the interesting part. Three decisions inside it are.

**`protected`, not `public`.** The table is owned by the GenServer and
nothing else may write to it, so "writes are serialised" is a property the
table enforces rather than a convention every caller has to remember. It
is also what keeps `insert_new/2` sufficient: with one writer, deciding
created-versus-replaced and performing the write really is one operation.

**Reads run in the calling process.** `get/1` and `get_all/0` send no
message to the store at all, with `read_concurrency` set because reads are
the point. This is the one place the design departs from the shape a
reader expects, and Concurrency below measures both what it buys and what
it does not.

**The table dies with its owner.** The data's lifetime is deliberately
unchanged from when the state was a map, which is the subject of
Durability.

The map did come first, and every read was a message to one process that
waited its turn behind every write. That is the design the figures below
are measured against.

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

`make bench` compares the two read paths. Both run in one VM and are
measured alternately inside each round, so a slow moment on the host lands
on both; what it reports is the ratio, which survives that, and the median
of several rounds with the spread printed beside it. On this machine, four
schedulers:

| readers | ETS ops/s | gen_server ops/s | ratio |
|---------|-----------|------------------|-------|
| 1       | ~3.4M     | ~0.3M            | ~10x  |
| 2       | ~5.0M     | ~0.36M           | ~13x  |
| 4       | ~8.7M     | ~0.44M           | ~19x  |
| 8       | ~9.5M     | ~0.53M           | ~18x  |

The ratio is not the interesting part. This is: adding readers multiplies
ETS throughput by roughly 2.3 to 3.8x across four cores depending on the
run, and the gen_server by about 1.5x at best and sometimes less than
one. One process handles one message at
a time, so its total is close to flat no matter how many callers arrive —
which is the whole argument, in a measurement rather than in prose.

Run it and the figures will differ; the shape is what reproduces.

Availability, which is the reason the change was made: `kv_http_tests`
suspends the GenServer with `sys:suspend/1` and asserts reads keep
answering `200` while writes report `503 store_unavailable`. Before this
change every verb timed out. `kv_store_tests` covers the other end — with
no store running at all, `get/1` returns `{error, unavailable}` rather than
crashing its caller.

Correctness under load: `kv_http_tests` drives 300 concurrent writes
followed by 300 concurrent reads, each writer sending a value derived from
its own key, and asserts every reader gets its own value back -- 300/300,
no 5xx. A crossed response fails the assertion rather than passing as a
plain 200.

### What is not measured

Absolute ops/s here means very little: this is one laptop running Docker
Desktop, and the spread column shows rounds varying by a third. Treat the
ratios and the scaling shape as the result and the raw figures as
illustration. A number worth quoting to anyone would come off a quiet
Linux host.

The first attempt at this measurement was thrown away twice, which is worth
recording because both failures are easy to repeat. Measuring the two
designs in separate runs put host noise between them, and it was wider than
the effect. Then `erl -pa _build/...` ran against beams the `_build` volume
had cached from the previous implementation, so both sides of the
comparison were secretly the same code — and duly measured the same. That
is the hazard the README warns about under `make clean`, walked into
anyway. `make bench` recompiles before it measures.

The harness itself then had two of its own, both caught by a run whose
scaling block contradicted the table above it. It measured everything
twice and printed the two results as though they were one, and its memory
rows charged the previous row's uncollected binaries to the next. Neither
changed a conclusion, but both are why the figures here are given as
ranges over runs rather than as single numbers.

### What this does not fix

A large value is still copied to whoever reads it. Moving the read out of
the GenServer moved where the copy happens, not whether it happens: one
client pulling a multi-megabyte entry still consumes CPU and allocator
bandwidth every other request needs.

Measured — one client looping over a 4MB value while small-key reads run
alongside — throughput retained is roughly 53-61% with ETS against 36-49%
through the GenServer, across several runs. Better, but both lose about
half, so this is not the fix for that problem.

If it mattered, the answer is not more concurrency. It is not storing
values large enough to care about, or handing back a reference instead of a
copy.

### Through HTTP, which is what a client actually sees

Every figure above measures kv_store directly. None of them is what the
service serves: between a client and the table sit a socket read, request
parsing, routing, JSON decoding and encoding, and a socket write.
`make bench-http` drives the real listener over persistent connections and
measures that. On four cores, through Docker Desktop -- each cell the range
of the per-run medians across three runs of five rounds:

| connections | GET req/s     | PUT req/s     |
|-------------|---------------|---------------|
| 1           | 4.3k - 4.5k   | 2.5k - 3.7k   |
| 4           | 3.9k - 12.5k  | 8.3k - 9.1k   |
| 16          | 20.7k - 23.0k | 15.3k - 19.6k |
| 64          | 18.6k - 24.5k | 14.7k - 18.9k |

Ranges, not single figures, and wide ones: within one run the five rounds
at sixteen connections spanned 11k to 26k. The 4-connection GET row is the
honest embarrassment -- two runs put it near 12k and one near 3.9k, which
is the host, not the server. Nothing below leans on a difference smaller
than the noise, and the shape only reproduces from sixteen connections up,
where both verbs flatten.

Set beside the in-process numbers, the gap is the whole point:

| | in kv_store | through HTTP | ratio |
|---|---|---|---|
| reads  | ~9M ops/s   | ~22k req/s | ~400x |
| writes | ~460k ops/s | ~17k req/s | ~27x  |

**The store is not the constraint. The HTTP layer is -- by 27x on writes
and 400x on reads.** Everything the concurrency work above achieved --
reads that scale across cores, a write path that does not queue behind
reads -- is real and is invisible from outside, because the request never
gets near those limits.

This is worth stating plainly because it changes what the earlier sections
mean. Both verbs flatten from sixteen connections -- reads in the low
twenties of thousands, writes in the middle to high teens -- and the
distance between them is the only trace the write serialisation leaves at
this level. It is a small trace: the path that serialises every write comes
within about a quarter of the path that serialises nothing, because the
socket, the parsing and the JSON dominate both. Removing the serialisation
would move a ceiling at 17k that the store itself does not reach until
460k, so sharding would be optimising the part already 27x faster than the
part in front of it.

If throughput ever needed to go up, the profitable places are in that
gap -- fewer allocations per request, a cheaper JSON path, HTTP/2 or
pipelining, more nodes behind a balancer -- and not in the store.

### Capacity

`make bench` also measures what one entry costs, because "how many fit in a
node" is what decides whether one node is the answer at all. Keys of 14
bytes, 20,000 entries per row, measured rather than estimated:

| value | ETS bytes/entry | VM bytes/entry | entries per GiB |
|-------|-----------------|----------------|-----------------|
| 16 B  | 144             | 217            | ~4.95M          |
| 64 B  | 144             | 264            | ~4.07M          |
| 256 B | 144             | 456            | ~2.35M          |
| 1 KiB | 144             | 1224           | ~0.88M          |

Two columns because they answer different questions, and taking only the
first would flatter the result badly. A value over 64 bytes is a refcounted
binary on the shared heap, so the table holds a pointer and its own figure
stays flat at 144 bytes no matter how large the value gets. The VM total
counts the binary too, and that is the number that fills a machine.

The rule that falls out: **roughly 200 bytes of overhead per entry, plus the
value.** So a 16 GiB node with headroom for the VM and the network stack
holds on the order of 10M entries at 1 KiB each, or tens of millions of
small ones. Doubling the key size moves it; the shape does not.

### Where one node stops

Memory is the first ceiling and the easiest to reason about — the table
above says where it is for a given value size.

The second is writes. They still go through one process by design, because
that is what makes created-vs-updated atomic, and `make bench` measures
what that costs:

| writers | ops/s | vs 1 writer |
|---------|-------|-------------|
| 1       | ~252k | 1.00x       |
| 2       | ~300k | 1.19x       |
| 4       | ~372k | 1.48x       |
| 8       | ~464k | 1.84x       |

Eight writers buy 1.84x, which is the serialisation showing plainly: the
process handles one message at a time and extra callers mostly keep its
mailbox from going empty rather than adding parallelism.

The conclusion is less dramatic than the shape suggests, and worth stating
because the shape invites the opposite one. The ceiling is around 460k
writes a second on one node -- on four cores, on a laptop, through Docker
Desktop. That is a great deal of writing. Removing the serialisation is
possible and is described below, but it should be done because a
measurement says the ceiling is being approached, not because a graph
flattens.

Two ways to remove it if it ever matters. Writes could go straight to a
public table with `write_concurrency`, since `ets:insert_new/2` is itself
atomic and answers created-vs-updated on its own -- at the cost of a
narrow race where a concurrent delete between the failed insert and the
overwrite makes "updated" the wrong word. Or the store could be sharded
across N processes by `phash2(Key) rem N`, keeping the guarantee exactly
and paying for it in `get_all/0` and `clear_all/0` becoming fan-outs. The
first is simpler and loosens a guarantee; the second is more machinery and
keeps it.

Past either ceiling the answer is more nodes, and then the question is how
keys are divided. Consistent hashing over the key is the usual choice and
fits here, since every operation names exactly one key and nothing spans
two — there are no multi-key transactions to break. What it costs is that
`get_all/0` and `clear_all/0` stop being single answers.

### Why in-process rather than Redis or Memcached

The brief asks for an in-memory store, and this is one — it is the cache,
not a service in front of one. Keeping it in-process buys the numbers
above: an ETS read is well under a microsecond in the calling process,
where a Redis round trip is tens to hundreds of microseconds on a good
network. That is two to three orders of magnitude, and it is the kind of
difference that changes what the code above it can afford to do per
request.

What would change the answer: state that must outlive a process restart
(see Durability), state shared by several nodes, or a working set past one
machine. Any of those and an external store earns its network hop, and the
hop is the cost being accepted — not a detail.

### Observability

Two questions an operator asks that the API cannot answer: is it busy, and
did something fail that the client saw but nobody recorded.

`/metrics` answers the first in Prometheus text -- responses by method and
status, store operations by result, and gauges for entries held and bytes
used. The counters live in a public ETS table with `write_concurrency` and
are incremented in the request process. Routing them through a metrics
process would have put back the queue the read path was moved out of, and
it would have done so at the worst moment: the busier the system, the
longer that queue, so the numbers would degrade exactly when they are
being read to find out why. A counter that cannot be written is dropped
rather than failing the request that produced it.

The gauges are read at scrape time from `ets:info/2` instead of being
tracked as the store changes, so they cannot drift from what they
describe.

Logging covers the failures that previously left no trace at all: the
store being unreachable, a body that stopped arriving, a body read that
failed for a reason the classifier collapsed away. All three are the same
shape -- the client learns something the operator does not, unless it is
written down. They are logged at warning, above the default `notice`
threshold, so they appear without reconfiguring anything. The listener
logs its port at notice on the way up.

What is deliberately absent: request duration. A histogram is the obvious
next metric and the one most worth having, but doing it properly means
bucket choices this has no traffic to inform.

### Durability

There is none, by design: the brief asks for an in-memory store. The table
is owned by the GenServer, so it dies with it. Under `one_for_one` the
supervisor restarts the store and **every key is gone**, while the listener
keeps answering `200` on `/health` as though nothing happened. That is the
right trade for the brief and the wrong one for anything that must not lose
data; persistence would be the next design decision, not a tuning exercise.

## Security

Nothing here is a security control by accident, so it is worth being
explicit about which of it is one, and about the much larger set of things
that are simply absent.

### What is in place

- The release runs as an unprivileged `kv` user, from an image holding the
  release and nothing else -- no shell beyond busybox, no compiler, no
  sources.
- Erlang distribution is confined to loopback and carries no committed
  cookie; the VM generates one per container at first boot. Reaching the
  node from another container is not possible over the network.
- Request bodies are capped at 1 MiB and bounded by a read deadline, so a
  single client can neither submit unbounded input nor hold a connection
  open indefinitely sending nothing.
- Keys are validated at the boundary, so nothing unaddressable is stored.
- ranch caps concurrent connections at 1024, its default, unchanged.

### What is absent

There is **no authentication and no authorisation**. Anything that can
reach the port can read, overwrite and delete any key; the service has no
concept of a caller at all. There is no TLS -- the listener is `ranch_tcp`
on `0.0.0.0`. There is no rate limiting beyond that connection cap, and no
audit trail: a successful delete leaves a counter increment and nothing
else.

The sharpest edge is the combination of no authentication and no quota.
Capacity above puts a node at roughly 5M small entries per GiB, and
nothing stops one client walking to that number. Memory exhaustion is the
cheapest denial of service available here and it requires no cleverness --
just a loop.

### What this assumes

That it sits on a trusted network, behind something that terminates TLS
and decides who is allowed to talk to it. That is a reasonable shape for
an internal cache and an unreasonable one for anything reachable from
outside, and the assumption is worth stating because nothing in the code
enforces it.

### What would change if it did not hold

In the order worth doing them:

1. **A quota** -- entries or bytes, rejecting or evicting past a
   threshold. It comes first because it is the only failure on this list
   that needs no attacker, just a busy client with a loop.
2. **Authentication**, at the edge or as a token check in the handler.
   Cheap, and it makes the rest of this list meaningful.
3. **TLS**, via `cowboy_tls` or terminated in front.
4. **Per-client rate limiting**, which needs identity, so it follows 2.
5. **Audit logging** of writes and deletes, which also needs identity to
   be worth anything.

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
