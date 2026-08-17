# Dowser.Client

`dowser_client` is the low-level HTTP/JSON transport shared by the Dowser
family of search-engine clients. It knows how to talk to a search backend
over HTTP, encode and decode request/response bodies, retry transient
failures, and normalize errors — but it knows nothing about any particular
search engine's API (queries, mappings, indices, etc.).

That backend-specific knowledge lives in dedicated packages built on top of
this one, such as [`dowser_elasticsearch`](https://github.com/GRoguelon/dowser_elasticsearch), 
which implements one particular database's search API using `dowser_client` as its
transport. Similar packages for other backends (noSQL search database) are 
planned but not yet ready for use.

**Install `dowser_elasticsearch` (or whichever backend package you need), not
`dowser_client` directly.** `dowser_client` is a dependency those packages
pull in for you; it isn't meant to be used stand-alone in application code.

## Why it exists

Every search backend needs the same plumbing: build a URL, attach auth
headers, serialize a body to JSON (or newline-delimited JSON for bulk APIs),
send it over HTTP, retry on transient failures, and decode the response.
Rather than duplicate that plumbing in every backend-specific package, it
lives once in `dowser_client`, and each backend package only has to
implement the parts that are actually specific to it — the API surface.

`dowser_client` also keeps the choice of HTTP library and JSON library out of
the application's hands entirely: it defines both as swappable **adapters**,
so a project can use Erlang's built-in `:httpc` and Elixir's built-in `JSON`
module with zero extra dependencies, or opt into `Req`/`:hackney` and
`Jason`/`Poison` when it already depends on them.

## How it works

### Configs

A `Dowser.Client.Config` bundles everything needed to reach one search
backend: its `:endpoint`, `:auth`, and the HTTP/JSON/codec adapters and
options to use. Configs are plain structs — build one inline, or configure
named ones at compile time:

```elixir
config :dowser_client,
  configs: [
    default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}],
    logs: [endpoint: "https://logs.internal:9200"]
  ]
```

Any function that accepts a `:config` option resolves `nil` to the `:default`
entry above (there is no other built-in fallback — a `:default` entry must be
configured, or `:config` must be passed explicitly on every call), an atom to
a named entry, and a map/keyword list to an ad-hoc inline config.

### Requests

`Dowser.Client.request/4` (and its `get/post/put/patch/delete` shortcuts) is
the entry point:

```elixir
Dowser.Client.get("/my-index/_search", config: :logs, params: %{size: 10})
Dowser.Client.post("/my-index/_doc", %{title: "hello"})
```

Given a method, path, body and options, it resolves everything about the
request — merged headers, joined URL and query string, the adapters to use,
and the encoded body — into a `Dowser.Client.Request` struct, hands it to the
HTTP adapter, retries it if needed, and decodes the response body with the
JSON adapter. The result is always `{:ok, %Dowser.Client.Response{}}` or
`{:error, exception}`; `Dowser.unwrap/1` turns that into the plain response
or a raised exception when you'd rather not pattern-match on every call.

Request/response bodies have a `:format` — `:json` (default), `:ndjson` for
bulk-style newline-delimited payloads, or `:raw` to pass bytes through
untouched. `:req_format`/`:resp_format` set each direction independently.

A `:json`/`:ndjson` response body is always JSON-decoded (string-keyed maps);
two more options shape what happens after that, both of them settable on a
`Dowser.Client.Config` as a default and overridable per request:

  * `:codec_adapter` — a module implementing `Dowser.Client.Codec`, which
    casts a decoded body's *values* beyond plain JSON — dates, geo points,
    whatever a backend package knows about — via its `decode/2`, and a
    request body's values via `encode/2`. Defaults to
    `Dowser.Client.Codec.Default`, which only applies `:keys` casting
    (below) and otherwise passes values through unchanged — `dowser_client`
    has no backend-specific knowledge of its own beyond that. A backend
    package like `dowser_elasticsearch` ships its own `:codec_adapter`,
    typically built with `Dowser.Client.Codec.Builder` plus a thin bridge —
    see [Codecs](#codecs) below.
  * `:keys` — `:strings` (default), `:atoms` or `:atoms!`; how the decoded
    body's keys are cast, however deeply nested. This is resolved into a
    `:key_fn` function and forwarded to `:codec_adapter` via `:codec_opts`;
    the default `Dowser.Client.Codec.Default` applies it, so keys are cast out of the box.
    A *custom* `:codec_adapter` is responsible for calling `opts[:key_fn]`
    itself, however deeply nested, if it wants the same behavior. `:atoms!` uses `String.to_existing_atom/1`, so
    an unrecognized key surfaces as a `Dowser.Client.Codec.Error` instead of
    silently growing the atom table.

```elixir
config = Dowser.Client.Config.new(endpoint: "...", codec_adapter: MyApp.Codec)
Dowser.Client.get("/my-index/_doc/1", config: config, keys: :atoms)
#=> {:ok, %Dowser.Client.Response{body: %{_id: "1", _source: %{title: "hello"}}}}
```

### Codecs

`Dowser.Client.Field` is a behaviour for casting a single value to and from
its wire representation — `load/2` (wire → richer term) and `dump/2` (the
reverse). `dowser_client` ships only the behaviour, no implementations; it
has no backend-specific knowledge of its own.

`Dowser.Client.Codec.Builder` builds a `load/2`/`dump/2` dispatcher from a
list of `Dowser.Client.Field` mappings, dispatching on a pattern matched
against field metadata:

```elixir
defmodule MyApp.Fields.Date do
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, %{"format" => "strict_date"}) when is_binary(value) do
    Date.from_iso8601(value)
  end

  @impl true
  def dump(%Date{} = date, %{"format" => "strict_date"}) do
    {:ok, Date.to_iso8601(date)}
  end

  def dump(value, _field), do: {:ok, value}
end

defmodule MyApp.FieldCodec do
  use Dowser.Client.Codec.Builder

  cast %{"type" => "date"}, MyApp.Fields.Date
end
```

Each `cast/2` expands into a pattern-matched `load/2`/`dump/2` clause
dispatching straight to the field module — no indirection at runtime. See
the `Dowser.Client.Codec.Builder` moduledoc for the `:inherit`, `:fallback`
and `:nil` options.

A `CodecBuilder`-built module implements `Dowser.Client.Field`'s per-*value*
contract, not `Dowser.Client.Codec`'s whole-*body* one — it can't be set
directly as `:codec_adapter`. Bridging the two means walking a document
against its own mapping/schema, which is inherently backend-specific
knowledge `dowser_client` doesn't have, so a backend package writes a thin
`Dowser.Client.Codec` that does the walk itself and dispatches into the
`CodecBuilder`-built module's `load/2`/`dump/2` per field — see the
`Dowser.Client.Codec.Builder` moduledoc for a worked example.

### Adapters

Two behaviours make the HTTP client and the JSON codec pluggable, so
`dowser_client` never hard-codes a dependency on any specific HTTP or JSON
library.

**`Dowser.Client.HTTP.Adapter`** — pure transport. Given a method, absolute
URL, headers and an already-encoded body, it performs the request and
returns a normalized `Dowser.Client.Response` or an error. It never touches
encoding/decoding. Bundled implementations:

  * `Dowser.Client.HTTP.Httpc` — Erlang's built-in `:httpc`, no extra
    dependency, used by default. Requires `:inets` and `:ssl` to be started
    (add them to `extra_applications` in `mix.exs`). Erlang's `:httpc` has no
    request-body slot for `GET`/`HEAD`/`TRACE`; passing a body for one of
    those methods returns `{:error, {:unsupported_body, method}}` rather than
    silently dropping it — use `Req` or `Hackney` for backends that expect a
    body on `GET` (e.g. Elasticsearch's `GET /_search`).
  * `Dowser.Client.HTTP.Req` — the [`Req`](https://hex.pm/packages/req)
    library, if you already depend on it.
  * `Dowser.Client.HTTP.Hackney` — [`:hackney`](https://hex.pm/packages/hackney).

**`Dowser.Client.JSON.Adapter`** — pure codec. `encode/2` turns an Elixir
term into `iodata`; `decode/2` turns a response binary into an Elixir term.
Both return tagged tuples rather than raising. Bundled implementations:

  * `Dowser.Client.JSON.Native` — Elixir's built-in `JSON` module, no extra
    dependency, used by default.
  * `Dowser.Client.JSON.Jason` — the [`Jason`](https://hex.pm/packages/jason)
    library.
  * `Dowser.Client.JSON.Poison` — the [`Poison`](https://hex.pm/packages/poison)
    library.

Adapters are resolved with the same precedence everywhere: an explicit
`:http_adapter`/`:json_adapter`/`:codec_adapter` option on a request, else
the adapter set on the `Dowser.Client.Config`, else
`config :dowser_client, :http_adapter` / `:json_adapter` / `:codec_adapter`
(read at request time, so it can be changed at runtime — e.g. in
`config/runtime.exs` — not just at compile time), else the built-in
`Httpc`/`Native`/`Dowser.Client.Codec.Default` defaults. This means a backend package like
`dowser_elasticsearch` can work out of the box with no extra dependencies,
while an application that already uses `Req` and `Jason` can switch to them
with a one-line config change — no code changes anywhere that calls
`Dowser.Client`.

### Errors

Errors are always Dowser exceptions, never a dependency's own exception type,
so callers only ever need to handle one set of shapes regardless of which
adapters are configured:

  * `Dowser.Client.Error` — config resolution, invalid `:format`/`:keys`/
    `:retry`, or an optional dependency (`Req`, `:hackney`, `Jason`,
    `Poison`) that isn't installed.
  * `Dowser.Client.JSON.Error` — body encoding or decoding failure.
  * `Dowser.Client.Codec.Error` — `:codec_adapter` `encode/2`/`decode/2` failure.
  * `Dowser.Client.HTTP.Error` — transport failure, after retries are
    exhausted.

### Testing

`Dowser.Client.HTTP.Stub` is an `HTTP.Adapter` for tests: point a config at
it and script the response with `stub/1`, and the rest of the pipeline (URL
building, headers, retries, JSON encoding/decoding) runs exactly as it would
against a real backend — no server required.

```elixir
test "indexes a document" do
  Dowser.Client.HTTP.Stub.stub(fn :put, url, _headers, body, _opts ->
    assert url == "http://localhost:9200/my-index/_doc/1"
    Dowser.Client.HTTP.Stub.json(201, %{"_id" => "1", "result" => "created"})
  end)

  config = Dowser.Client.Config.new(endpoint: "http://localhost:9200", http_adapter: Dowser.Client.HTTP.Stub)

  assert {:ok, %{status: 201}} =
           Dowser.Client.put("/my-index/_doc/1", %{title: "hello"}, config: config)
end
```

The stub lives in the calling process, so `async: true` tests don't interfere
with each other; see the module docs for scripting multiple endpoints and for
testing from a process other than the one that called `stub/1`.

## HTTP configuration

Every HTTP adapter (`Dowser.Client.HTTP.Httpc`, `Req`, `Hackney`) is pinned to
HTTP/1.1 with keep-alive, and ships with connect/receive timeouts and retry
behavior tuned for talking to a search database cluster. Everything below is
overridable per request.

### Timeouts

| Adapter | Connect | Receive | Override via |
| --- | --- | --- | --- |
| `Httpc` | 2s | 30s | `http_opts: [http_options: [connect_timeout: ..., timeout: ...]]` |
| `Req` | 2s | 30s | `http_opts: [connect_options: [timeout: ...], receive_timeout: ...]` |
| `Hackney` | 2s | 30s | `http_opts: [connect_timeout: ..., recv_timeout: ...]` |

```elixir
Dowser.Client.request(:get, "/_search", nil, http_opts: [http_options: [timeout: 5_000]])
```

### Retries

Requests retry automatically on transient failures — connection errors
(refused, closed, timed out, unreachable) and retryable HTTP statuses (`429`,
`502`, `503`, `504`) — for every HTTP method, using exponential backoff with
full jitter.

Default policy: `max_attempts: 3`, `base_delay_ms: 200`, `max_delay_ms: 2_000`,
`retryable_statuses: [429, 502, 503, 504]`.

```elixir
# Override any key
Dowser.Client.request(:post, "/_bulk", docs, retry: [max_attempts: 5])

# Disable retries for this request
Dowser.Client.request(:get, "/_search", nil, retry: false)
```

## Installation

Don't add `dowser_client` to your application directly. Add the
backend-specific package instead — currently
[`dowser_elasticsearch`](https://github.com/GRoguelon/dowser_elasticsearch):

```elixir
def deps do
  [
    {:dowser_elasticsearch, "~> 0.1.0"}
  ]
end
```

`dowser_elasticsearch` depends on `dowser_client` itself, so it's pulled in
automatically. Other backend packages (Meilisearch, Typesense, and others)
will follow the same pattern once they're ready.
