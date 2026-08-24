# KV Store - Design Document

## Start here

This is longer than the brief needs. Three sections carry the argument and
the rest is the reasoning behind them:

1. [**Reads do not go through the store process**](#concurrency). They run
   in the caller, straight from ETS, so they neither queue behind writes
   nor behind each other. Writes stay serialised deliberately.
2. [**The HTTP layer is the bottleneck, not the store**](#through-http-which-is-what-a-client-actually-sees)
   -- by about 17x on writes and 400x on reads, measured. That is why
   there is no sharding here.
3. [**What one entry costs**](#capacity), in bytes and in entries per GiB,
   because that is what decides how many nodes a working set needs.

The limits are stated as plainly as the capabilities:
[no durability](#durability), [no authentication](#security), and
[no expiry](#what-this-is-not-a-cache).

## Architecture

Cowboy answers HTTP on port 8080 and routes to one handler; a supervised
GenServer owns an ETS table of `{Key, Value, Bytes}` and takes every
write; reads go to the table directly. `set/2`, `get/1`, `delete/1`,
`clear_all/0` and `get_all/0` are the whole store API.

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

| readers | ETS ops/s   | gen_server ops/s | ratio       |
|---------|-------------|------------------|-------------|
| 1       | 1.3M - 3.7M | 145k - 367k      | 9.2x - 11.3x  |
| 2       | 2.3M - 6.3M | 143k - 396k      | 15.5x - 17.2x |
| 4       | 6.0M - 9.0M | 282k - 442k      | 17.2x - 20.1x |
| 8       | 6.5M - 11.5M | 340k - 559k     | 19.0x - 21.8x |

Each cell is the range of the per-run medians over three runs. They are
wide, and the rounds inside them are wider: four readers have spanned 2.6M
to 10.7M within one run. An earlier version of this table gave one figure
per cell, and a later run on the same machine reproduced almost none of
them.

The ratio is not the interesting part. This is: going from one reader to
eight multiplies ETS throughput by 2.9 to 4.8x across four cores depending
on the run, and the gen_server by 1.2 to 2.3x. Every run agrees on the
direction even where the figures disagree by a factor of three -- one
process handles one message at a time, so its total flattens no matter how
many callers arrive, and the table it is being compared against does not.
That is the whole argument, in a measurement rather than in prose.

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
| writes | ~290k ops/s | ~17k req/s | ~17x  |

**The store is not the constraint. The HTTP layer is -- by 17x on writes
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
about 290k, so sharding would be optimising the part already 17x faster
than the part in front of it.

If throughput ever needed to go up, the profitable places are in that
gap -- fewer allocations per request, a cheaper JSON path, HTTP/2 or
pipelining, more nodes behind a balancer -- and not in the store.

### Capacity

`make bench` also measures what one entry costs, because "how many fit in a
node" is what decides whether one node is the answer at all. Keys of 14
bytes, 20,000 entries per row, measured rather than estimated:

| value | ETS bytes/entry | VM bytes/entry | entries per GiB |
|-------|-----------------|----------------|-----------------|
| 16 B  | 152             | 221 - 224      | ~4.86M          |
| 64 B  | 152             | 271 - 272      | ~3.95M          |
| 256 B | 152             | 464 - 468      | ~2.30M          |
| 1 KiB | 152             | 1233 - 1235    | ~0.87M          |

Every figure here is one word larger than it was before `max_bytes`: rows
carry the entry's byte charge as a third element, so the quota pays for
itself at 8 bytes per entry. Worth noticing rather than quietly
restating -- it is the clearest cost this feature has, and it is small.

Two columns because they answer different questions, and taking only the
first would flatter the result badly. A value over 64 bytes is a refcounted
binary on the shared heap, so the table holds a pointer and its own figure
stays flat at 152 bytes no matter how large the value gets. The VM total
counts the binary too, and that is the number that fills a machine.

The rule that falls out: **roughly 200 bytes of overhead per entry, plus the
value.** That 200 is not only a figure in this table -- it is what
`kv_store` charges each entry against `max_bytes`, so the ceiling an
operator sets is in the same units this measured.

So a 16 GiB node with headroom for the VM and the network stack holds on
the order of 10M entries at 1 KiB each, or tens of millions of
small ones. Doubling the key size moves it; the shape does not.

### Where one node stops

Memory is the first ceiling and the easiest to reason about — the table
above says where it is for a given value size.

The second is writes. They still go through one process by design, because
that is what makes created-vs-updated atomic, and `make bench` measures
what that costs:

| writers | ops/s       | vs 1 writer   |
|---------|-------------|---------------|
| 1       | 145k - 215k | 1.00x         |
| 2       | 138k - 234k | 0.81x - 1.09x |
| 4       | 250k - 329k | 1.19x - 2.27x |
| 8       | 228k - 322k | 1.09x - 1.97x |

Three runs, and the ranges overlap enough that only the ends of the table
are really being compared: eight writers buy somewhere between 1.1x and
2.3x. That is the serialisation showing plainly -- the process handles one
message at a time, so extra callers mostly keep its mailbox from going
empty rather than adding parallelism.

**These figures include the byte ceiling.** Without it -- the same harness
against the store before `max_bytes` existed -- eight writers reached 437k
and 458k on two runs, against 228k to 322k with it. The quota costs
roughly a third of write throughput, and the cost is in the write path
itself: charging the entry and reading the limit happen on every write. A
binary fast path for the size calculation changed nothing measurable, and
replacing the per-write `application:get_env` with a constant recovered
part of the gap but not reliably more than the noise, so neither is in the
code. The limit stays readable at runtime, which is worth more than
throughput a client cannot reach.

The conclusion is less dramatic than the shape suggests, and worth stating
because the shape invites the opposite one. The ceiling is somewhere near
300k writes a second on one node -- on four cores, on a laptop, through
Docker Desktop -- against a transport that delivers under 20k. Removing
the serialisation is possible and is described below, but it should be
done because a measurement says the ceiling is being approached, not
because a graph flattens.

The same figures set the write timeout. A write waits one second for the
store and is then reported as `503`, which is load shedding rather than a
safety margin -- reads never enter the mailbox, so writes are the only
operation that can queue at all. Against a store that serves 300k a
second, a write it has not reached within one is not running late; it is
behind a queue that is not draining. The previous five seconds bought
nothing for that case and let a thousand connections' worth of doomed
requests wait out a five-second wall before failing anyway.

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

### What this is not: a cache

Nothing here expires. There is no TTL on an entry and no eviction when the
table fills -- `max_bytes` refuses the write instead, with `507`. That is
the right behaviour for a store of record, where losing an entry the
client believes is stored is worse than refusing a new one, and it is the
wrong behaviour for a cache, where the opposite holds.

The brief asks for a key-value store and says nothing about expiry, so
this is the shape it was built to. It is worth naming rather than leaving
implicit, because plenty of workloads that reach for an in-memory store --
sessions, tokens, anything with a natural lifetime -- want the other
behaviour, and would be quietly broken by a store that keeps everything
until it refuses to keep any more.

Two ways to change it, if a workload needed it:

**A TTL per entry.** The row already carries a third element, so a fourth
holding an expiry timestamp costs one word. Reads would have to check it
-- which puts a comparison on the hot path that currently has none -- and
something has to reclaim the space, since a key nobody reads again is
never noticed. A periodic sweep with `ets:select_delete/2` over expired
rows is the usual answer, and it trades a predictable stall against
memory held past its usefulness.

**LRU eviction at the ceiling.** Instead of refusing at `max_bytes`, evict
until the write fits. This needs recency, which this design deliberately
does not track: a read touches no shared state at all, which is exactly
what makes reads scale here. Recording recency would put a write on the
read path and undo that. The usual escapes are approximation -- sampling a
few keys and evicting the oldest, as Redis does -- or accepting a segmented
structure and the write it costs.

Both are real work with real trade-offs against the read path, which is
why neither is here rather than half-here.

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
- The store is bounded. `max_bytes` (1 GiB by default) is a ceiling on
  what the table may hold, and a write past it is refused with `507`
  rather than taken. The running total is kept exactly, which costs
  nothing only because writes are already serialised through one process.
- ranch caps concurrent connections at 1024, its default, unchanged.

### What is absent

There is **no authentication and no authorisation**. Anything that can
reach the port can read, overwrite and delete any key; the service has no
concept of a caller at all. There is no TLS -- the listener is `ranch_tcp`
on `0.0.0.0`. There is no rate limiting beyond that connection cap, and no
audit trail: a successful delete leaves a counter increment and nothing
else.

The sharpest edge is the lack of authentication. Anyone who can reach the
port can delete or overwrite anything, and nothing records that they did.

Until recently it was worse: with no ceiling on the table, one client
looping on writes could take the node down entirely, which needed no
cleverness and no attacker -- a bug would do. `max_bytes` now bounds that
to filling the store rather than killing the process, so the failure is a
node that refuses writes and keeps serving reads. That is still a denial
of service, and per-client quotas are the fix, which needs identity, which
needs authentication -- so it stays on the list below rather than being
claimed as solved.

### What this assumes

That it sits on a trusted network, behind something that terminates TLS
and decides who is allowed to talk to it. That is a reasonable shape for
an internal cache and an unreasonable one for anything reachable from
outside, and the assumption is worth stating because nothing in the code
enforces it.

### What would change if it did not hold

In the order worth doing them:

1. **Authentication**, at the edge or as a token check in the handler.
   Cheap, and it makes the rest of this list meaningful. It is first now
   that the store is bounded; before that, a ceiling was, because that
   failure needed no attacker at all.
2. **TLS**, via `cowboy_tls` or terminated in front.
3. **Per-client quotas and rate limiting**. Both need identity, so they
   follow 1. The node-wide ceiling stops one client killing the process;
   only a per-client one stops them crowding everyone else out of it.
4. **Audit logging** of writes and deletes, which also needs identity to
   be worth anything.
5. **Eviction**, so a full store degrades instead of refusing. Covered
   under [what this is not](#what-this-is-not-a-cache), including why the
   recency it needs would cost the read path.

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
