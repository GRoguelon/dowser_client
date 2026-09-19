# Dowser.Client

`dowser_client` is the low-level HTTP/JSON transport shared by the Dowser
family of search-engine clients. It knows how to talk to a search backend
over HTTP, encode and decode request/response bodies, retry transient
failures, and normalize errors — but it knows nothing about any particular
search engine's API (queries, mappings, indices, etc.).

That backend-specific knowledge lives in dedicated packages built on top of
this one, such as
[`dowser_elasticsearch`](https://github.com/GRoguelon/dowser_elasticsearch),
which implements one database's search API using `dowser_client` as its
transport. Similar packages for other NoSQL search databases are planned but not
yet ready for use.

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

It needs Elixir 1.18+ (for the built-in `JSON` module) and OTP 25+ (for
`:public_key.cacerts_get/0`, the OS trust store TLS verifies against).

`dowser_client` has **no dependencies**. HTTP is OTP's own `:httpc` — every
search backend it targets speaks HTTP/1.1, which is exactly what `:httpc` does —
sent through its own `:dowser_client` profile (connection pool, keep-alive
settings, cookie store) rather than `:httpc`'s shared `:default` one, with a
separate profile per cluster when you want one. JSON is Elixir's built-in `JSON`
module — no `Jason`, no `Poison`, nothing to pick.

## How it works

### Contexts

A `Dowser.Client.Context` is one search backend to talk to: its `:endpoint`,
`:auth`, the `:httpc` profile to send through, and how to cast what it returns
and what you send it. The name follows [`elastic/cli`](https://github.com/elastic/cli)'s
notion of a *context* — a named cluster you address by name instead of
repeating its coordinates at every call site. Contexts are plain structs —
build one inline, or configure named ones at compile time:

```elixir
config :dowser_client,
  contexts: [
    default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}],
    logs: [endpoint: "https://logs.internal:9200", profile: :logs]
  ]
```

Any function that accepts a `:context` option resolves `nil` to the `:default`
entry above (there is no other built-in fallback — a `:default` entry must be
configured, or `:context` must be passed explicitly on every call), an atom to
a named entry, and a map/keyword list to an ad-hoc inline context.

`:auth` accepts, each applied as an `authorization` header:

```elixir
{:basic, "dXNlcjpwYXNz"}          # Basic <value>, already encoded
{:basic, "user", "changeme"}      # Basic <base64("user:changeme")>
{:api_key, "VnVhQ2ZHY0..."}       # ApiKey <value>
{:api_key, "id", "api_key"}       # ApiKey <base64("id:api_key")>
{:bearer, "token"}                # Bearer <token>
{:header, "x-custom-auth", "..."} # any header you like
```

### Requests

`Dowser.Client.request/4` (and its `get/post/put/patch/delete` shortcuts) is
the entry point:

```elixir
Dowser.Client.get("/my-index/_search", context: :logs, params: %{size: 10})
Dowser.Client.post("/my-index/_doc", %{title: "hello"})
```

Given a method, path, body and options, it resolves everything about the
request — merged headers, joined URL and query string, the casting to apply,
and the encoded body — into a `Dowser.Client.Request` struct, hands it to
`Dowser.Client.HTTP`, retries it if needed, and decodes the response body. The
result is always `{:ok, %Dowser.Client.Response{}}` or `{:error, exception}`;
`Dowser.unwrap/1` turns that into the plain response or a raised exception when
you'd rather not pattern-match on every call.

`:params` takes a map or keyword list; a list value is comma-joined
(`params: [_source: ["a", "b"]]` becomes `?_source=a%2Cb`), which is how these
APIs spell a multi-value parameter.

A `%Dowser.Client.Response{}` carries the `:status`, the `:headers` as a map of
downcased string names (duplicates comma-joined), and the decoded `:body`. Any
completed exchange is `{:ok, response}` whatever its status — a `404` is a
response, not an error — so only transport, encoding and casting failures come
back as `{:error, exception}`.

Request/response bodies have a `:format` — `:json` (default), `:ndjson` for
bulk-style newline-delimited payloads, or `:raw` to pass bytes through
untouched. `:req_format`/`:resp_format` set each direction independently.

A `:json`/`:ndjson` response body is always JSON-decoded into plain,
**string-keyed** terms, and that is where `dowser_client` stops. Casting a value
beyond JSON — `"2026-09-19"` into `~D[2026-09-19]` — means knowing where
documents sit in the envelope, which index each came from, and what that index'
mapping says. All of that is one particular search engine's API, which
`dowser_client` knows nothing about. So the second pass is a black box the
backend package supplies:

  * `:keys` — `:strings` (default, no casting), `:atoms`, `:atoms!`, or any
    `(String.t() -> term)` function. `:atoms!` uses `String.to_existing_atom/1`,
    so an unknown key surfaces as an error instead of silently growing the atom
    table.
  * `:decoder` — the decoder and the options it needs:

    ```elixir
    MyDecoder                       # module exporting decode/2
    {MyDecoder, mapping: mapping}   # ... with its options
    fun                             # (body, opts -> term)
    {fun, mapping: mapping}         # ... with its options
    ```

    It is called with the decoded body and those options plus `:key_fn` and
    `:context`, and owns the result: it walks its own envelope, resolves its own
    mappings, casts its own fields, and applies `:key_fn` itself.

Without a `:decoder`, `:keys` is applied on its own. With neither, there is no
second pass at all. Both resolve per request, then from the context, then from
`config :dowser_client, ...`; a request setting `:decoder` replaces the
context's outright, options included.

```elixir
Dowser.Client.get("/articles/_search",
  keys: :atoms,
  decoder: Dowser.Elasticsearch.Decoder
)

#=> {:ok, %Dowser.Client.Response{body: %{hits: %{hits: [
#=>   %{_index: "articles", _id: "1", _source: %{
#=>     title: "hello",
#=>     published_at: ~D[2026-09-19],
#=>     run_window: %{"gte" => ~D[2026-09-01], "lte" => ~D[2026-09-30]}
#=>   }}
#=> ]}}}}
```

A raising decoder comes back as
`{:error, %Dowser.Client.Error{reason: {:decode_failed, exception}}}` rather than
crashing the caller.

The request direction encodes **document sources only** — never a query. A
source's fields are described by the mapping of the index it is going to, so it
can be encoded exactly; a query has no such anchor, because the same value means
different things in a range clause, a script parameter, an aggregation boundary
or a suggester. So build queries in the shape the backend expects, and tell
`dowser_client` where the source is when there is one:

  * `:encoder` — the same four shapes as `:decoder` above, with `encode/2` as the
    module callback and `(source, opts -> term)` as the function, resolved the
    same way. Its options are whatever the encoder needs — the target index, a
    mapping — plus `:context`, which is always added.
  * `:encode` — where the source sits in *this* request's body: `false`
    (default), `true` (the body is the source), a path (`["doc"]`), or a list of
    paths (`[["doc"], ["upsert"]]`). Per request only — the call site is the only
    place that knows.

```elixir
# the body is the source
Dowser.Client.put("/articles/_doc/1", document,
  encoder: {Dowser.Elasticsearch.Encoder, index: "articles"},
  encode: true
)

# a partial update: the source is under "doc"
Dowser.Client.post("/articles/_update/1", %{"doc" => partial},
  encoder: {Dowser.Elasticsearch.Encoder, index: "articles"},
  encode: ["doc"]
)

# a search: nothing to encode, so :encode is simply not passed
Dowser.Client.post("/articles/_search", query)
```

An encoder whose options never vary — one that resolves the index from the
document itself, say — belongs on the context, leaving call sites to pass only
`:encode`.

A path is a list of `Access` keys, and a path that isn't present is skipped
rather than created.

An `:ndjson` payload is cast a **line at a time**, in both directions — the unit
of a bulk or multi-search body is the line, not the list. So the encoder sees one
entry per call and can tell an action line from a document, and a path applies
within each entry:

```elixir
# the encoder passes actions through and casts documents
def encode(%{"index" => _action} = line, _opts), do: line
def encode(document, opts), do: cast(document, opts[:index])

# ... or let a path do it: every line with a "doc" is encoded, the rest skipped
Dowser.Client.post("/_bulk", entries, format: :ndjson, encode: ["doc"])
```

A response decoded as `:ndjson` reaches the decoder the same way, entry by
entry.

`Date`, `Time`, `NaiveDateTime` and `DateTime` need no encoder at all — Elixir's
`JSON` already writes them as ISO 8601. An encoder is for shapes JSON has no
opinion about (`Date.Range`, `Decimal`) or a format the mapping dictates. The
pass is skipped for a `nil` or `:raw` body, and a raising encoder comes back as
`{:error, %Dowser.Client.Error{reason: {:encode_failed, exception}}}`.

### What a decoder and encoder look like

`dowser_client` never inspects a value, so both hooks are ordinary modules in the
backend package. A decoder walks its own envelope — it is the only place that
knows a hit carries its index, and therefore which mapping to cast it against:

```elixir
defmodule Dowser.Elasticsearch.Decoder do
  def decode(body, opts), do: do_decode(body, Keyword.fetch!(opts, :key_fn))

  # A hit carries its own index, so the mapping to cast it against can be
  # resolved right here.
  defp do_decode(%{"_index" => index, "_source" => _source} = hit, key_fn) do
    Map.new(hit, fn
      {"_source" = key, source} -> {key_fn.(key), decode_source(source, index, key_fn)}
      {key, value} -> {key_fn.(key), do_decode(value, key_fn)}
    end)
  end

  defp do_decode(value, key_fn) when is_non_struct_map(value) do
    Map.new(value, fn {key, value} -> {key_fn.(key), do_decode(value, key_fn)} end)
  end

  defp do_decode(value, key_fn) when is_list(value), do: Enum.map(value, &do_decode(&1, key_fn))
  defp do_decode(value, _key_fn), do: value

  defp decode_source(source, index, key_fn) do
    {:ok, %{"properties" => properties}} = MappingCache.fetch(index)

    Enum.reduce(properties, %{}, fn {field, options}, acc ->
      case Map.fetch(source, field) do
        {:ok, value} -> Map.put(acc, key_fn.(field), load(value, options))
        :error -> acc
      end
    end)
  end

  # Per-field casting, however that backend prefers to organise it.
  defp load(value, %{"type" => "date"}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> value
    end
  end

  defp load(value, _options), do: value
end
```

An encoder is the mirror: one function over a document source, given whatever it
needs through its options.

```elixir
defmodule Dowser.Elasticsearch.Encoder do
  def encode(source, opts) do
    {:ok, %{"properties" => properties}} = MappingCache.fetch(opts[:index])

    Map.new(source, fn {field, value} -> {field, dump(value, properties[field])} end)
  end

  defp dump(%Date{} = date, %{"type" => "date"}), do: Date.to_iso8601(date)
  defp dump(value, _options), do: value
end
```

`dowser_client` used to ship a `Dowser.Client.Field` behaviour and a
`Codec.Builder` macro for that per-field layer. They are gone: nothing in the
pipeline ever called them, and how a backend organises its own casting — a
`cast/2` dispatcher, a `case` on `"type"`, or a protocol — is its business.
`Dowser.CoreExt.Keyable.transform_keys/2` remains for a decoder that only needs
the key half.

### Transport

`Dowser.Client.HTTP` is the whole transport: given a method, absolute URL,
headers and an already-encoded body, it performs the request with `:httpc` and
returns a normalized `Dowser.Client.Response` or an error. It never touches
encoding/decoding, and there is nothing to choose or install — `:inets` and
`:ssl` ship with OTP (they're already in this package's
`extra_applications`).

Every request is HTTP/1.1 with keep-alive, sent through a named `:httpc`
profile — see [HTTP configuration](#http-configuration) below for profiles,
timeouts and TLS.

`:httpc`'s request tuple has no body slot for `GET`, but search backends do
expect one (Elasticsearch's `GET /_search`), so a `GET` carrying a body is sent
as a `POST` on the same path — which every such backend accepts — and logged at
debug level. A body on `HEAD`/`TRACE`, where it is meaningless, returns
`{:error, {:unsupported_body, method}}` rather than being dropped silently.

### JSON

`Dowser.Client.JSON` wraps Elixir's built-in `JSON` module: `encode/1` to
`iodata`, `decode/1` to string-keyed terms, both returning a
`Dowser.Client.JSON.Error` rather than raising.
`Dowser.Client.NDJSON` does the same line by line for bulk-style payloads.
There is no adapter to choose and no optional dependency to install.

### Errors

Errors are always Dowser exceptions, never a dependency's own exception type,
so callers only ever need to handle one set of shapes:

  * `Dowser.Client.Error` — context resolution, an invalid
    `:auth`/`:format`/`:keys`/`:decoder`/`:encoder`/`:encode`/`:retry`, or a
    `:keys`, `:decoder` or `:encoder` function that raised while casting a body.
  * `Dowser.Client.JSON.Error` — body encoding or decoding failure.
  * `Dowser.Client.HTTP.Error` — transport failure, after retries are
    exhausted. Carries `:httpc`'s own reason — `:timeout`,
    `:socket_closed_remotely`, or a `{:failed_connect, _}` tuple, which is where
    a refused connection and a TLS `{:tls_alert, _}` both show up — plus the
    method, URL, profile and attempt count.

### Testing

`Dowser.Client.HTTP.Stub.stub/1` intercepts every request made by the calling
process, so the rest of the pipeline (URL building, headers, retries, JSON
encoding/decoding) runs exactly as it would against a real backend — no server
required, and nothing to point at the stub.

It replaces the transport and only the transport: the context is still resolved,
so a test needs one — either the configured `:default` or an inline one, as
here.

```elixir
test "indexes a document" do
  Dowser.Client.HTTP.Stub.stub(fn :put, url, _headers, body, _opts ->
    assert url == "http://localhost:9200/my-index/_doc/1"
    assert IO.iodata_to_binary(body) == ~s({"title":"hello"})

    Dowser.Client.HTTP.Stub.json(201, %{"_id" => "1", "result" => "created"})
  end)

  assert {:ok, %{status: 201, body: %{"result" => "created"}}} =
           Dowser.Client.put("/my-index/_doc/1", %{title: "hello"},
             context: [endpoint: "http://localhost:9200"]
           )
end
```

The stub lives in the calling process, so `async: true` tests don't interfere
with each other, and an unstubbed process still talks to the network; see the
module docs for scripting multiple endpoints and for testing from a process
other than the one that called `stub/1`.

## HTTP configuration

Requests go over `:httpc`, pinned to HTTP/1.1 with keep-alive, with
connect/receive timeouts, connection pooling and retry behavior tuned for
talking to a search database cluster. Everything below can be set globally
(`config :dowser_client, ...`), per context, or per request — most specific
wins, with `:http_opts`, `:ssl` and `:profile_opts` merging per key across the
three tiers rather than replacing each other wholesale.

### Profiles

A `:httpc` profile is an isolated manager with its own connection pool,
session settings and cookie store. `dowser_client` sends through its own
`:dowser_client` profile rather than `:httpc`'s shared `:default` one, so its
settings and its keep-alive sessions are never shared with the rest of the
application. Give each cluster its own profile when they should not share a
pool:

```elixir
config :dowser_client,
  contexts: [
    default: [endpoint: "https://search.internal:9200", profile: :search],
    logs: [endpoint: "https://logs.internal:9200", profile: :logs]
  ]
```

Profiles are started on demand, the first time a request needs one, and
configured once with `:httpc.set_options/2` from `:profile_opts`. The defaults:

| Setting | Default | Why |
| --- | --- | --- |
| `max_sessions` | `20` | concurrent keep-alive connections per host/port (`:httpc`'s own default is 2) |
| `max_keep_alive_length` | `100` | requests queued on one session |
| `keep_alive_timeout` | `120_000` | how long an idle session is kept |
| `cookies` | `:disabled` | a search API has no use for a cookie store |

Anything `:httpc.set_options/2` accepts can be set — `:pipeline_timeout`,
`:max_pipeline_length`, `:proxy`, `:https_proxy`, `:ipfamily`, `:socket_opts`,
`:unix_socket`, ...:

```elixir
config :dowser_client, profile_opts: [max_sessions: 50, pipeline_timeout: 5_000]
```

`Dowser.Client.HTTP.Profile.info/1` reports `:httpc`'s own view of a profile —
its open sessions, queued requests and current options — or
`{:error, {:not_started, name}}` before the first request has started it, since
profiles are created on demand.

### Headers

`http_opts: [headers: ...]` takes a map or a list of `{name, value}` pairs at any
tier, merged by name (case-insensitively). Weakest to strongest:

1. the `content-type`/`accept` derived from the request/response format,
2. `config :dowser_client, http_opts: [headers: ...]`,
3. the context's `:auth`, as an `authorization` header,
4. the context's own `http_opts[:headers]`,
5. the request's `http_opts[:headers]`.

So a request can override anything — including the derived `content-type` — and a
context header can override the `authorization` its own `:auth` produced.

```elixir
Dowser.Client.post("/_search", query, http_opts: [headers: %{"x-opaque-id" => "trace-42"}])
```

### Timeouts

| Setting | Default | Override via |
| --- | --- | --- |
| connect | 2s | `http_opts: [connect_timeout: ...]` |
| receive | 30s | `http_opts: [timeout: ...]` |

```elixir
Dowser.Client.request(:get, "/_search", nil, http_opts: [timeout: 5_000])
```

`:autoredirect`, `:proxy_auth`, `:relaxed`, `:full_result`, `:headers_as_is`,
`:socket_opts` and `:ipv6_host_with_brackets` are passed to `:httpc` too, and
`http_opts: [http_options: [...], options: [...]]` are escape hatches merged
last into `:httpc`'s own two option lists. An unrecognized key is an error
(`{:unknown_http_opts, keys}`) rather than a silently ignored setting.

### TLS

An `https://` endpoint is verified by default: the chain against the OS trust
store (`:public_key.cacerts_get/0`), the certificate identity against the URL
host, SNI sent, TLS 1.2+. Nothing to configure for a normal cluster.

`http_opts: [ssl: [...]]` adjusts it. Keys not listed below are passed to
`:ssl` verbatim, and override the computed value:

```elixir
# localhost cluster with a self-signed certificate: no verification at all
config :dowser_client,
  contexts: [dev: [endpoint: "https://localhost:9200", http_opts: [ssl: [insecure: true]]]]

# SSH tunnel or port-forward: real CA, but the hostname will never match
http_opts: [ssl: [verify_hostname: false]]

# a private CA
http_opts: [ssl: [cacertfile: "/etc/ssl/certs/internal-ca.pem"]]
```

  * `:verify` — `true` (default) or `false`; `:verify_peer`/`:verify_none` also
    accepted.
  * `:insecure` — `true` is shorthand for `verify: false`.
  * `:verify_hostname` — `false` keeps full chain verification but accepts any
    name in the certificate.
  * `:cacerts` / `:cacertfile` — an explicit trust store, replacing the OS one.
  * `:sni` — `:auto` (default; disabled for an IP-address host, which cannot
    legally be sent as an SNI value), `:disable`, or a name.
  * `:versions` — defaults to `[:"tlsv1.2", :"tlsv1.3"]`; `:depth` defaults
    to `3`.

See `Dowser.Client.HTTP.SSL` for the full contract.

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
