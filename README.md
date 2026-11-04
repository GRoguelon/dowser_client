# Dowser.Client

`dowser_client` is the foundation shared by the Dowser family of search-engine
clients. It holds what every backend needs the same way:

  * **repos** — one module per cluster, configured and supervised like an
    `Ecto.Repo` (`Dowser.Repo`);
  * **the transport** — HTTP over `:httpc`, JSON, retries, TLS, errors;
  * **mapping-driven casting** — turning a document's JSON into Elixir terms
    and back, from its index mapping: dates, ranges, IP addresses, structs.

What it doesn't know is any particular engine's API — its endpoints, its
query language, its mapping types. That lives in a package per engine, built
on this one:
[`dowser_elasticsearch`](https://github.com/GRoguelon/dowser_elasticsearch) and
[`dowser_opensearch`](https://github.com/GRoguelon/dowser_open_search).

**Install the backend package you need, not `dowser_client` directly.** It
pulls `dowser_client` in for you; this README is for what you configure
through it — repos, HTTP, casting — and for anyone writing a backend
package.

## Why it exists

Every search backend needs the same plumbing: build a URL, attach auth
headers, serialize a body to JSON (or newline-delimited JSON for bulk APIs),
send it over HTTP, retry on transient failures, and decode the response.
Rather than duplicate that plumbing in every backend-specific package, it
lives once in `dowser_client`, and each backend package only has to
implement the parts that are actually specific to it — the API surface.

It needs Elixir 1.18+ (for the built-in `JSON` module) and OTP 26+ — TLS
verification reads the OS trust store through `:public_key.cacerts_get/0`, which
exists from OTP 25, but 26 is the oldest release CI covers.

`dowser_client` has **no required dependencies**. HTTP is OTP's own `:httpc` —
every search backend it targets speaks HTTP/1.1, which is exactly what
`:httpc` does — sent through a profile of its own per repo (connection pool,
keep-alive settings, cookie store) rather than `:httpc`'s shared `:default`
one. JSON is Elixir's built-in `JSON` module — no `Jason`, no `Poison`,
nothing to pick. `:telemetry` is optional: where your application has it, a
mapping that couldn't be fetched emits an event.

## How it works

### Repos

A repo is one cluster to talk to. An application defines one module per
cluster with its backend package (`use Dowser.OpenSearch.Repo, otp_app:
:my_app`, built on `Dowser.Repo`), configures it under its own application,
and starts it in its supervision tree — like an `Ecto.Repo`:

```elixir
config :my_app, MyApp.Search,
  endpoint: "http://localhost:9200",
  auth: {:basic, "user", "changeme"}

config :my_app, MyApp.Logs, endpoint: "https://logs.internal:9200"

children = [MyApp.Search, MyApp.Logs]
```

A started repo resolves its configuration once — an optional `init/2`
callback included, for secrets that can't live in config files — and keeps it
in `:persistent_term`; one that isn't started (a script, a Mix task) resolves
it per request. Each repo has its own `:httpc` profile, so two clusters never
share a connection pool. With `verify: true`, a repo checks at startup that
its endpoint runs the engine its backend package expects.

Every function that sends a request takes the cluster as its `:repo` option: a
repo module, or the attributes of an ad-hoc one for a script
(`repo: [endpoint: "http://localhost:9200"]`). `dowser_client` itself has no
default; each backend package has its own (`config :dowser_opensearch,
default_repo: MyApp.Search`). A repo resolves into a `Dowser.Repo.Config`, the
struct the rest of the client works with.

A repo module can also be started any number of times under other names, each
with its own configuration — a cluster per tenant, say. These dynamic
instances are chosen per process, or per call, as with `Ecto.Repo`:

```elixir
{:ok, _} = MyApp.Search.start_link(name: :tenant_a, endpoint: "https://a.internal:9200")

MyApp.Search.put_dynamic_repo(:tenant_a)                 # every call from this process
MyApp.Search.with_dynamic_repo(:tenant_a, fn -> ... end) # for the duration of a function
Dowser.Client.get("/_cat/indices", repo: {MyApp.Search, :tenant_a})  # one call
```

A repo also exposes the HTTP verbs, for any endpoint the backend package
doesn't cover — `MyApp.Search.post("/_plugins/_ml/models/_search", query)`.

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
Dowser.Client.get("/my-index/_search", repo: MyApp.Logs, params: %{size: 10})
Dowser.Client.post("/my-index/_doc", %{title: "hello"}, repo: MyApp.Search)
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
**string-keyed** terms first. Casting a value beyond JSON — `"2026-09-19"` into
`~D[2026-09-19]` — is an optional second pass, configured on the repo or the
request. The backend packages' codecs plug into it, built on the casting
described in [Mapping-driven casting](#mapping-driven-casting) below; a
decoder of your own can too:

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
    `:repo_config` (the repo, resolved), and owns the result: it walks its own
    envelope, resolves its own mappings, casts its own fields, and applies
    `:key_fn` itself.

Without a `:decoder`, `:keys` is applied on its own. With neither, there is no
second pass at all. Both resolve per request, then from the repo, then from
`config :dowser_client, ...`; a request setting `:decoder` replaces the
repo's outright, options included.

```elixir
Dowser.Client.get("/articles/_search",
  repo: MyApp.Search,
  keys: :atoms,
  decoder: Dowser.Elasticsearch.Codec
)

#=> {:ok, %Dowser.Client.Response{body: %{hits: %{hits: [
#=>   %{_index: "articles", _id: "1", _source: %{
#=>     title: "hello",
#=>     published_at: ~D[2026-09-19],
#=>     run_window: Date.range(~D[2026-09-01], ~D[2026-09-30])
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
    mapping — plus `:repo_config`, which is always added.
  * `:encode` — where the source sits in *this* request's body: `false`
    (default), `true` (the body is the source), a path (`["doc"]`), or a list of
    paths (`[["doc"], ["upsert"]]`). Per request only — the call site is the only
    place that knows.

```elixir
# the body is the source
Dowser.Client.put("/articles/_doc/1", document,
  repo: MyApp.Search,
  encoder: {Dowser.Elasticsearch.Codec, index: "articles"},
  encode: true
)

# a partial update: the source is under "doc"
Dowser.Client.post("/articles/_update/1", %{"doc" => partial},
  repo: MyApp.Search,
  encoder: {Dowser.Elasticsearch.Codec, index: "articles"},
  encode: ["doc"]
)

# a search: nothing to encode, so :encode is simply not passed
Dowser.Client.post("/articles/_search", query, repo: MyApp.Search)
```

An encoder whose options never vary — one that resolves the index from the
document itself, say — belongs on the repo, leaving call sites to pass only
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
Dowser.Client.post("/_bulk", entries, repo: MyApp.Search, format: :ndjson, encode: ["doc"])
```

A response decoded as `:ndjson` reaches the decoder the same way, entry by
entry.

`Date`, `Time`, `NaiveDateTime` and `DateTime` encode on their own — Elixir's
`JSON` writes them as ISO 8601 — but only an encoder writes them in the format
and precision the mapping declares. An encoder is also for shapes JSON has no
opinion about (`Date.Range`, `{lat, lon}`, `Decimal`). The
pass is skipped for a `nil` or `:raw` body, and a raising encoder comes back as
`{:error, %Dowser.Client.Error{reason: {:encode_failed, exception}}}`.

### Mapping-driven casting

The backend packages' codecs (`Dowser.Elasticsearch.Codec`,
`Dowser.OpenSearch.Codec`) are thin configurations of `Dowser.Codec`, the
casting engine that lives here. It is split by concern, one module each:

| Module | Concern |
| --- | --- |
| `Dowser.Envelope` | a response body: finding the documents in it — hits, `_source`, `inner_hits` |
| `Dowser.Source` | one document: objects, nested fields, arrays, structs — the mapping decides what a value is, never its shape |
| `Dowser.Type`, `Dowser.Type.*` | one leaf value: a date, a range, an IP address, a `geo_point` |
| `Dowser.Mapping` | where a mapping comes from — implemented by `Dowser.MappingCacher` (the cluster's, cached) |
| `Dowser.Schema` | a document module: its struct, and how to load and dump it |

Five options decide how documents are cast, per request, on the codec, or in
the backend's application environment:

  * `:mapping` — where the mapping comes from: a map, a `Dowser.Mapping`
    module, or a document module. Defaults to the backend's mapping cacher,
    which the application starts in its supervision tree.
  * `:struct` — load each document into a document module's struct, and dump
    it back. `:keys` casts the envelope around it, never its fields.
  * `:types` — the `Dowser.Type` module leaf values go through.
  * `:unknown_fields` — `:keep` a field the mapping doesn't declare, or
    `:raise` a `Dowser.UnknownFieldError`.
  * `:mapping_failure` — `:error`, `:warn` or `:ignore` when the mapping can't
    be fetched.

Only nine date formats are cast — those an Elixir function reads exactly, to
a `Date`, `Time`, `NaiveDateTime` or UTC `DateTime`; see `Dowser.Type.Date`.
Any other value its type doesn't recognize comes back as stored.

A decoder or encoder of your own is still a plain module or function, as
above — `Dowser.Source.load/3` and `Dowser.Source.dump/3` do the walking for
one that only needs a different mapping source or type module, and
`Dowser.CoreExt.Keyable.transform_keys/2` the key half for one that casts
nothing.

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

  * `Dowser.Client.Error` — no repo, or one that can't be resolved, an invalid
    `:auth`/`:format`/`:keys`/`:decoder`/`:encoder`/`:encode`/`:retry`, or a
    `:keys`, `:decoder` or `:encoder` function that raised while casting a body.
  * `Dowser.Client.JSON.Error` — body encoding or decoding failure.
  * `Dowser.Client.HTTP.Error` — transport failure, after retries are
    exhausted. Carries `:httpc`'s own reason — `:timeout`,
    `:socket_closed_remotely`, or a `{:failed_connect, _}` tuple, which is where
    a refused connection and a TLS `{:tls_alert, _}` both show up — plus the
    method, URL, profile and attempt count.
  * `Dowser.MappingError` — the mapping a document had to be cast against
    couldn't be fetched (or its cacher isn't started), under the default
    `mapping_failure: :error`.
  * `Dowser.UnknownFieldError` — a field the mapping doesn't declare, under
    `unknown_fields: :raise`.

The backend packages return the last two as themselves, not wrapped in the
`Dowser.Client.Error` a failing decoder otherwise becomes.

### Testing

`Dowser.Client.HTTP.Stub.stub/1` intercepts every request made by the calling
process, so the rest of the pipeline (URL building, headers, retries, JSON
encoding/decoding) runs exactly as it would against a real backend — no server
required, and nothing to point at the stub.

It replaces the transport and only the transport: the repo is still resolved,
so a test needs one — a repo module, or an inline one, as here.

```elixir
test "indexes a document" do
  Dowser.Client.HTTP.Stub.stub(fn :put, url, _headers, body, _opts ->
    assert url == "http://localhost:9200/my-index/_doc/1"
    assert IO.iodata_to_binary(body) == ~s({"title":"hello"})

    Dowser.Client.HTTP.Stub.json(201, %{"_id" => "1", "result" => "created"})
  end)

  assert {:ok, %{status: 201, body: %{"result" => "created"}}} =
           Dowser.Client.put("/my-index/_doc/1", %{title: "hello"},
             repo: [endpoint: "http://localhost:9200"]
           )
end
```

The stub lives in the calling process, so `async: true` tests don't interfere
with each other, and an unstubbed process still talks to the network; see the
module docs for scripting multiple endpoints and for testing from a process
other than the one that called `stub/1`.

For a unit test that only needs a canned answer, mock the repo instead. A
repo is the `Dowser.Repo` behaviour, and every request goes through its
`request/4`, so a [Mox](https://hexdocs.pm/mox) mock stands in for one:

```elixir
Mox.defmock(MyApp.SearchMock, for: Dowser.Repo)

Mox.expect(MyApp.SearchMock, :request, fn :get, "/_cluster/health", _body, _opts ->
  {:ok, %Dowser.Client.Response{status: 200, headers: %{}, body: %{"status" => "green"}}}
end)
```

The mock replaces the whole transport — encoding, decoding and casting
included — so the body it returns is exactly what the caller gets. To test
the casting too, stub the HTTP layer as above.

#### Mock the repo with Mimic

[Mimic](https://hexdocs.pm/mimic) stubs the functions of an existing module,
per test process. A test-only repo module becomes the default repo in the test
environment, so the code under test — which names no repo — talks to it, and
each test says what `request/4` answers. `request/4` is the one function every
API call goes through.

```elixir
# mix.exs
defp deps do
  [
    # ...
    {:mimic, "~> 1.10", only: :test}
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_env), do: ["lib"]
```

```elixir
# test/support/search_mock.ex — a repo like any other, compiled for tests only
defmodule MyApp.SearchMock do
  use Dowser.OpenSearch.Repo, otp_app: :my_app
end
```

```elixir
# config/test.exs — the default repo is the mock in tests
config :my_app, MyApp.SearchMock, endpoint: "http://search.test"
config :dowser_opensearch, default_repo: MyApp.SearchMock
```

```elixir
# test/test_helper.exs
Mimic.copy(MyApp.SearchMock)
ExUnit.start()
```

```elixir
defmodule MyApp.PostsTest do
  use ExUnit.Case, async: true
  use Mimic

  test "searches the posts" do
    expect(MyApp.SearchMock, :request, fn :post, "/posts/_search", _query, _opts ->
      {:ok, %Dowser.Client.Response{status: 200, headers: %{}, body: %{"hits" => %{"hits" => []}}}}
    end)

    # MyApp.Posts.search/1 calls Dowser.OpenSearch.Search.search(query, index: "posts"),
    # with no :repo — so it goes to the default repo, the mock.
    assert {:ok, %{"hits" => %{"hits" => []}}} = MyApp.Posts.search("hello")
  end
end
```

A few things to know:

- The stub stands in for the whole transport, so the body it returns is what
  the caller gets — nothing is decoded or cast. Let the request through with
  `call_original/3` where the casting matters, or stub the HTTP layer instead.
- Mimic stubs are per process, which keeps `async: true` tests apart. A request
  made from another process — a `Task`, a GenServer — needs
  `Mimic.allow(MyApp.SearchMock, self(), pid)`, or `set_mimic_global` in a test
  that isn't async.
- Mimic replaces calls *into* the module. The repo's own verbs
  (`MyApp.SearchMock.get/2`, …) reach `request/4` from inside it, so a test
  calling them directly stubs the verb it calls.
- Calls that name a repo (`repo: MyApp.Search`) bypass the default: point
  `repo:` at the same mock in tests, or have the code read its repo from
  configuration.

With `dowser_elasticsearch`, the same goes for `use Dowser.Elasticsearch.Repo`
and `config :dowser_elasticsearch, default_repo: ...`.

## HTTP configuration

Requests go over `:httpc`, pinned to HTTP/1.1 with keep-alive, with
connect/receive timeouts, connection pooling and retry behavior tuned for
talking to a search database cluster. Everything below can be set globally
(`config :dowser_client, ...`), per repo, or per request — most specific
wins, with `:http_opts`, `:ssl` and `:profile_opts` merging per key across the
three tiers rather than replacing each other wholesale.

### Profiles

A `:httpc` profile is an isolated manager with its own connection pool,
session settings and cookie store. `dowser_client` never sends through
`:httpc`'s shared `:default` one, so its settings and its keep-alive sessions
are never shared with the rest of the application. Each repo has a profile of
its own, named after the repo module, so two clusters never share a pool
either; an ad-hoc `[endpoint: ...]` repo uses the `:dowser_client` profile.
`:profile` picks another:

```elixir
config :my_app, MyApp.Logs, endpoint: "https://logs.internal:9200", profile: :logs
```

Profiles are started when their repo starts, or on demand the first time a
request needs one, and configured once with `:httpc.set_options/2` from
`:profile_opts`. The defaults:

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
`{:error, {:not_started, name}}` before its repo, or a first request, has
started it.

### Headers

`http_opts: [headers: ...]` takes a map or a list of `{name, value}` pairs at any
tier, merged by name (case-insensitively). Weakest to strongest:

1. the `content-type`/`accept` derived from the request/response format,
2. `config :dowser_client, http_opts: [headers: ...]`,
3. the repo's `:auth`, as an `authorization` header,
4. the repo's own `http_opts[:headers]`,
5. the request's `http_opts[:headers]`.

So a request can override anything — including the derived `content-type` — and a
repo header can override the `authorization` its own `:auth` produced.

```elixir
Dowser.Client.post("/_search", query,
  repo: MyApp.Search,
  http_opts: [headers: %{"x-opaque-id" => "trace-42"}]
)
```

### Timeouts

| Setting | Default | Override via |
| --- | --- | --- |
| connect | 2s | `http_opts: [connect_timeout: ...]` |
| receive | 30s | `http_opts: [timeout: ...]` |

```elixir
Dowser.Client.request(:get, "/_search", nil, repo: MyApp.Search, http_opts: [timeout: 5_000])
```

`:autoredirect`, `:proxy_auth`, `:relaxed`, `:full_result`, `:headers_as_is`,
`:socket_opts` and `:ipv6_host_with_brackets` are passed to `:httpc` too, and
`http_opts: [http_options: [...], options: [...]]` are escape hatches merged
last into `:httpc`'s own two option lists. An unrecognized key is an error
(`{:unknown_http_opts, keys}`) rather than a silently ignored setting.

### Compression

`:httpc` neither asks for a compressed response nor decompresses one.
`http_opts: [compressed: true]` does both: it sends `accept-encoding: gzip`
(unless the request already names an encoding) and decompresses a gzipped
response before it is decoded. Search responses are repetitive JSON that gzip
shrinks several times over, so wherever the network is slower than the cluster
— a VPN, another region — it is the larger part of the time a request takes:

```elixir
config :my_app, MyApp.Search,
  endpoint: "https://search.example.com",
  http_opts: [compressed: true]
```

A gzipped response is decompressed whether or not it was asked for. One whose
body isn't valid gzip returns `{:error, :invalid_gzip_body}`.

### TLS

An `https://` endpoint is verified by default: the chain against the OS trust
store (`:public_key.cacerts_get/0`), the certificate identity against the URL
host, SNI sent, TLS 1.2+. Nothing to configure for a normal cluster.

`http_opts: [ssl: [...]]` adjusts it. Keys not listed below are passed to
`:ssl` verbatim, and override the computed value:

```elixir
# localhost cluster with a self-signed certificate: no verification at all
config :my_app, MyApp.Search,
  endpoint: "https://localhost:9200",
  http_opts: [ssl: [insecure: true]]

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

Requests retry automatically on transient failures, using exponential backoff
with full jitter — but only when the retry is safe. What that means depends on
how the request failed:

  * **It never reached the server** (refused, unresolvable, unreachable) or
    **the server rejected it** (`429`, `503`): nothing was applied, so the
    request is always retried.
  * **Ambiguous** (a timeout, a connection dropped in flight, `502`/`504`): the
    request may have been applied, with no answer to say so, so it is retried
    only when it is idempotent.

`:idempotent` defaults to the method — `GET`, `HEAD`, `PUT`, `DELETE`,
`OPTIONS` and `TRACE` yes, `POST` and `PATCH` no — which is what stops a
timed-out `POST /_bulk` from indexing everything twice. A caller who knows
better overrides it:

```elixir
# A search is a POST, but it writes nothing
Dowser.Client.request(:post, "/_search", query, repo: MyApp.Search, retry: [idempotent: true])

# Override any key
Dowser.Client.request(:post, "/_bulk", docs, repo: MyApp.Search, retry: [max_attempts: 5])

# Disable retries for this request
Dowser.Client.request(:get, "/_search", nil, repo: MyApp.Search, retry: false)
```

A `Retry-After` response header (seconds or HTTP date) is obeyed in place of
the computed backoff, up to `:max_retry_after_ms`; `:max_elapsed_ms` bounds the
whole request in wall-clock time, however many attempts are left.

Default policy: `max_attempts: 3`, `max_elapsed_ms: nil`, `base_delay_ms: 200`,
`max_delay_ms: 2_000`, `retryable_statuses: [429, 503]`,
`ambiguous_statuses: [502, 504]`, `respect_retry_after: true`,
`max_retry_after_ms: 60_000`.

## Installation

Don't add `dowser_client` to your application directly. Add the backend
package for your engine instead:

```elixir
def deps do
  [
    {:dowser_elasticsearch, "~> 0.5.0"}
    # or {:dowser_opensearch, "~> 0.3.0"}
  ]
end
```

Each depends on `dowser_client` itself, so it's pulled in automatically.
Other backend packages (Meilisearch, Typesense, and others) will follow the
same pattern once they're ready.
