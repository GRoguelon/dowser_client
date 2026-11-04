# Upgrading from 0.3 to 0.4

0.4.0 replaces contexts with **repos**: one module per cluster, configured under
your own application and started in your supervision tree, like an
`Ecto.Repo`. It also takes over the casting `dowser_elasticsearch` and
`dowser_opensearch` each carried a copy of.

Most applications don't depend on `dowser_client` directly: upgrade your
backend package and follow its guide — "Upgrading to v0.3" in
[`dowser_opensearch`](https://hexdocs.pm/dowser_opensearch), or
[`dowser_elasticsearch`'s `UPGRADE_0_5`](https://hexdocs.pm/dowser_elasticsearch/UPGRADE_0_5.html)
— which covers the parts below that reach you through it. Read this one if you
call `Dowser.Client` yourself, write a decoder or encoder, or maintain a
backend package.

Start with the table, then read
[Watch out for silence](#watch-out-for-silence): the one change the compiler
can't point you to.

## At a glance

| 0.3 | 0.4 |
| --- | --- |
| `config :dowser_client, contexts: [default: [...], logs: [...]]` | one `Dowser.Repo` module per cluster, configured with `config :my_app, MyApp.Search, ...` |
| `context: :logs` | `repo: MyApp.Logs` |
| `context: [endpoint: "..."]` | `repo: [endpoint: "..."]` |
| no `:context` → the `:default` named context | no `:repo` → `{:error, %Dowser.Client.Error{reason: :no_repo}}`; the backend packages fall back to their own `:default_repo` |
| `Dowser.Client.Context` | `Dowser.Repo.Config` — the same struct, renamed |
| `Dowser.Client.Context.fetch/1` | removed — `Dowser.Repo.config/1`, or `MyApp.Search.config()` |
| a decoder's or encoder's `opts[:context]` | `opts[:repo_config]` |
| the backend packages' `codec:` option | `types:` — `codec:` is now an error naming it |
| a backend cacher's `lookup/2` → `{:ok, nil}` when not started | `{:error, {:not_started, cacher}}` — the application starts it |
| `{:unknown_context, name}` | `:no_repo`, `{:unknown_repo, name}` or `{:invalid_repo, repo, message}` |
| every request on the `:dowser_client` `:httpc` profile | each repo on a profile of its own, named after the module |
| a backend cacher's `put(index, mapping, context: ...)` | `put(index, mapping, repo: ...)` — required |
| — | `Dowser.Type`, `Dowser.Source`, `Dowser.Envelope`, `Dowser.Codec`, `Dowser.MappingCacher`, `Dowser.MappingError` |

## 1. Dependencies

```elixir
{:dowser_client, "~> 0.4.0"}
```

Your backend package pulls it in for you, so bumping that one is usually all
there is to it.

`:telemetry` is now an optional dependency of `dowser_client` — the
failed-mapping-fetch event moved here with the casting. Nothing changes if you
don't use it; if you do, it is already in your dependency tree.

## 2. Contexts become repos

Each named context becomes a module:

```elixir
defmodule MyApp.Search do
  use Dowser.OpenSearch.Repo, otp_app: :my_app       # or Dowser.Elasticsearch.Repo
end

defmodule MyApp.Logs do
  use Dowser.OpenSearch.Repo, otp_app: :my_app
end
```

Its entry moves from `:dowser_client`'s environment to your application's,
under the module's name — the keys are the same:

```diff
- config :dowser_client,
-   contexts: [
-     default: [endpoint: "https://search.internal:9200", auth: {:basic, "app", "secret"}],
-     logs: [endpoint: "https://logs.internal:9200", profile: :logs]
-   ]
+ config :my_app, MyApp.Search,
+   endpoint: "https://search.internal:9200",
+   auth: {:basic, "app", "secret"}
+
+ config :my_app, MyApp.Logs, endpoint: "https://logs.internal:9200"
```

and the repos go in your supervision tree:

```elixir
children = [MyApp.Repo, MyApp.Search, MyApp.Logs, MyAppWeb.Endpoint]
```

A started repo resolves its configuration once and keeps it in
`:persistent_term`. A repo that isn't started — a script, a Mix task, `iex`
without the application — still works, resolving it on every request.

A secret that can't live in a config file goes in an `init/2` callback, called
with `:supervisor` when the repo starts and `:runtime` otherwise:

```elixir
defmodule MyApp.Search do
  use Dowser.OpenSearch.Repo, otp_app: :my_app

  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :auth, {:api_key, MyApp.Secrets.fetch!("search")})}
  end
end
```

`verify: true` makes a repo check at startup that its endpoint runs the engine
its backend package expects; see `Dowser.Repo`.

### Dynamic repos

Where 0.3 needed one named context per cluster, a repo module can be started
several times under other names, each with its own configuration — a cluster
per tenant, or clusters only known at runtime:

```elixir
{:ok, _} = MyApp.Search.start_link(name: :tenant_a, endpoint: "https://a.internal:9200")

MyApp.Search.put_dynamic_repo(:tenant_a)                  # every call from this process
MyApp.Search.with_dynamic_repo(:tenant_a, fn -> ... end)  # for the duration of a function
Dowser.Client.get("/_cat/indices", repo: {MyApp.Search, :tenant_a})  # one call
```

See `Dowser.Repo` for the details.

## 3. `:context` is `:repo`

```diff
- Dowser.Client.get("/_cluster/health", context: :logs)
+ Dowser.Client.get("/_cluster/health", repo: MyApp.Logs)

- Dowser.Client.get("/_cluster/health", context: [endpoint: "http://localhost:9200"])
+ Dowser.Client.get("/_cluster/health", repo: [endpoint: "http://localhost:9200"])
```

A request that still passes `:context` fails with a `Dowser.Client.Error`
saying the option is now `:repo`, so the test suite finds every call site.

`dowser_client` itself has **no default repo**: a call to `Dowser.Client`
without `:repo` returns `{:error, %Dowser.Client.Error{reason: :no_repo}}`
where it used to fall back to the `:default` context. The backend packages have
a default of their own — `config :dowser_opensearch, default_repo:
MyApp.Search` — so calls through them can keep leaving it out.

`Dowser.Client.Context` is now `Dowser.Repo.Config` — the same struct, with
the same fields, under the name of what it is: a repo's resolved
configuration. `Config.resolve/1` takes a repo module where it took a context
name.

A repo also exposes the HTTP verbs, for an endpoint nothing else covers:

```elixir
MyApp.Search.post("/_plugins/_ml/models/_search", %{query: %{match_all: %{}}})
```

## 4. Each repo has its own connection pool

In 0.3, every context shared the `:dowser_client` `:httpc` profile unless it
named one. In 0.4 a repo's profile defaults to the repo module itself, so two
clusters never share a pool, and a repo's `:profile_opts` apply to its pool
alone. `profile: :name` still picks one explicitly; an ad-hoc
`[endpoint: ...]` repo still uses `:dowser_client`.

Global settings — `config :dowser_client, profile_opts: ...`, `keys: ...`,
`http_opts: ...` — are read as before, under the repo's own.

## 5. Decoders and encoders

A decoder or encoder now receives the repo, resolved, as `:repo_config` — a
`%Dowser.Repo.Config{}` — where it received `:context`:

```diff
  def decode(body, opts) do
-   %Dowser.Client.Context{endpoint: endpoint} = opts[:context]
+   %Dowser.Repo.Config{endpoint: endpoint} = opts[:repo_config]
```

The backend packages' codecs already read it; only a decoder or encoder of
your own needs this change.

## 6. Tests

`Dowser.Client.HTTP.Stub` works as before, but a request needs a repo now:

```diff
  assert {:ok, %{status: 201}} =
-          Dowser.Client.put("/my-index/_doc/1", %{title: "hello"})
+          Dowser.Client.put("/my-index/_doc/1", %{title: "hello"},
+            repo: [endpoint: "http://localhost:9200"]
+          )
```

A backend cacher's `put/3` needs `repo:` too — and now raises without one. It
used to resolve the `:default` context, and when there was none, store nothing
without a word.

### Mock repos

A repo is the `Dowser.Repo` behaviour, and every request goes through its
`request/4`, so a Mox mock can stand in for one in a test:
`Mox.defmock(MyApp.SearchMock, for: Dowser.Repo)`, then
`repo: MyApp.SearchMock`. It replaces the whole transport — decoding and
casting included.

## 7. For backend package authors: the shared casting

The casting `dowser_elasticsearch` and `dowser_opensearch` each had a copy of
lives here now, one concern per module:

| Module | Concern |
| --- | --- |
| `Dowser.Type`, `Dowser.Type.*` | one leaf value: a date, a range, an IP address |
| `Dowser.Source` | one document: objects, nested fields, arrays, structs |
| `Dowser.Envelope` | a response body: finding the documents in it |
| `Dowser.Codec` | the decoder/encoder engine, configured by the backend |
| `Dowser.MappingCacher` | the mapping cache — `use Dowser.MappingCacher, otp_app: ...` |
| `Dowser.MappingError` | a mapping that couldn't be fetched |

A backend package keeps a thin codec handing `Dowser.Codec` its configuration
— its application, its cacher, and the mapping types that are opaque on it.

`Dowser.Codec` takes five casting options — `:mapping`, `:struct`, `:types`,
`:unknown_fields` and `:mapping_failure` — and two behaviours plug into them:
`Dowser.Mapping` (where a mapping comes from; the mapping cachers implement
it) and `Dowser.Schema` (a document module, for `:struct`). `Dowser.Source`
names its type module `:types`, like the request option.

## Watch out for silence

These change what a value *is*, with no error to tell you so. The backend
guides cover them in detail; in short:

- **Dates are only cast for nine formats.** A date field with any other
  format — including none at all, which the cluster reads as
  `strict_date_optional_time||epoch_millis` — now comes back as the stored
  string, and is written as given. See `Dowser.Type.Date` for the nine, and the
  backend guide for a type module that keeps casting an index you can't
  remap.
- **Dates are written at their format's exact precision, and in UTC.** A
  `_millis` format gets three digits even for a whole second; a `DateTime` in
  another zone is written as its UTC instant.
- **Ranges are only cast when the Elixir struct holds them exactly.** A
  `date_range` needs `strict_date`; an open-ended range or `gt`/`lt` bounds
  come back as stored.
- **The mapping decides what a value is, not its shape.** A `geo_point`
  stored as `{"lat": …, "lon": …}` now loads to `{lat, lon}` — it used to stay
  a map.
