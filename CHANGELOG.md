# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Breaking — see [UPGRADE_GUIDE_0_4.md](UPGRADE_GUIDE_0_4.md) for the path from
0.3.

### Added

- **`Dowser.Repo`: one module per cluster, replacing contexts.** A backend
  package builds on it (`use Dowser.OpenSearch.Repo, otp_app: :my_app`); the
  application configures the repo under its own app (`config :my_app,
  MyApp.Search, endpoint: ...`) and starts it in its supervision tree, like an
  `Ecto.Repo`. Started, it resolves its configuration once — an optional
  `init/2` callback included, for secrets — into `:persistent_term`; not
  started, it resolves it per request. Each repo has its own `:httpc` profile by
  default, exposes `request/4` and the HTTP verbs for any endpoint, and with
  `verify: true` checks at startup that its endpoint runs the engine its backend
  package expects (`engine/0`).
- **Dynamic repos.** A repo module can be started any number of times under
  other names (`MyApp.Search.start_link(name: :tenant_a, endpoint: ...)`), each
  with its own configuration and connection pool. A process picks one with
  `put_dynamic_repo/1` or `with_dynamic_repo/2`, and a single call with
  `repo: {MyApp.Search, :tenant_a}`.

- **Mapping-driven casting, shared by `dowser_elasticsearch` and
  `dowser_opensearch`.** The casting both packages carried their own copy of now
  lives here, split three ways so that each concern is in one place:

  | Module | Concern |
  | --- | --- |
  | `Dowser.Type`, `Dowser.Type.*` | one leaf value: a date, a range, an IP address, … |
  | `Dowser.Source` | one document: objects, nested fields, arrays, structs |
  | `Dowser.Envelope` | a response body: finding the documents in it |
  | `Dowser.Codec` | the decoder/encoder engine a backend codec configures |
  | `Dowser.MappingCacher` | the mapping cache, one instance per backend (`use Dowser.MappingCacher, otp_app: ...`) |
  | `Dowser.MappingError` | a mapping that could not be fetched |

  A backend package supplies what differs: its application environment and
  telemetry prefix, its cacher, and the types that are opaque on it
  (`flat_object` on OpenSearch, `flattened` on Elasticsearch).

- **`NaiveDateTime` and `Time` date formats.** A `date` field formatted
  `strict_date_hour_minute_second` (or `…_millis`) loads to a `NaiveDateTime`
  and dumps without an offset; one formatted `strict_hour_minute_second` (or
  `…_millis`) loads to a `Time`.
- **`long_range` is cast to a `Range`**, like `integer_range`.
- **`-00:00` is read as UTC.** `DateTime.from_iso8601/1` rejects it, so such a
  value used to come back as a string.

### Changed

- **Breaking: `:context` is now `:repo`, and named contexts are gone.** Every
  request names its cluster with `repo:` — a `Dowser.Repo` module, or
  `[endpoint: ...]` for a script. `config :dowser_client, contexts: [...]` is no
  longer read, and `dowser_client` has no default: a request without `:repo`
  returns `{:error, %Dowser.Client.Error{reason: :no_repo}}` (the backend
  packages fall back to their own `:default_repo`). Passing `:context` returns
  an error pointing at `:repo`. `Dowser.MappingCacher.put/4` takes `:repo` too,
  and raises without one rather than storing nothing.
- **Breaking: `Dowser.Client.Context` is `Dowser.Repo.Config`**, the same
  struct, and a decoder or encoder receives it as `:repo_config` rather than
  `:context`.
- **Breaking: only nine date formats are cast**, each the one an Elixir function
  reads: `epoch_millis`, `epoch_second`, `strict_date`,
  `strict_date_hour_minute_second(_millis)`, `strict_date_time(_no_millis)` and
  `strict_hour_minute_second(_millis)`. Any other format — including none at all
  (`strict_date_optional_time||epoch_millis` to the backend), the non-strict
  spellings and Java patterns — returns its values as stored, in both
  directions. Give a date field one of the nine formats to have it cast.
- **A date is written at exactly its format's precision.** A `DateTime`,
  `NaiveDateTime` or `Time` is truncated to the second or the millisecond as the
  format declares, and padded to three digits for a `_millis` format —
  `~U[2026-08-11 00:00:00Z]` used to be written to `strict_date_time` without
  the `.000` it requires. A date-time written to `strict_date` keeps its date.

- **The mapping decides what a value is, never its shape.** A value whose
  mapping entry has `"properties"` (or is an `object`/`nested`) is walked as an
  object; any other typed entry is a leaf, and its whole value goes to its type
  — even when that value is a map. The backend packages used to tell a range
  from an object by its `gte`/`lte` keys, and never handed a `geo_point` written
  as `%{"lat" => _, "lon" => _}` to its type, so it came back as a map rather
  than `{lat, lon}`; both now follow the mapping. A leaf map that its type
  leaves uncast has its keys go through `:keys` like the rest of the document.
- **A `DateTime` in any zone is dumped as its UTC instant.** One built with
  `tzdata` in, say, `America/New_York` used to be written with its own offset,
  so the same instant was written two ways. Loading already gave one UTC
  `DateTime`; both directions now behave the same with the default UTC-only
  time-zone database and with `tzdata`.
- **Ranges are only cast when the Elixir struct holds them exactly.** A
  `date_range` becomes a `Date.Range` only when its field is formatted
  `strict_date`; with any other format, or none, a range whose bounds had a time
  used to have them loaded as `DateTime`s and handed to `Date.range/2`, which
  raised. An `integer_range`/`long_range` becomes a `Range` only with integer
  `gte` and `lte` bounds, `gte` no greater than `lte`. Anything else — an
  open-ended range, `gt`/`lt` bounds, a descending pair — is returned as stored,
  and only a range stepping by 1 is dumped.
- **A field the mapping doesn't know is left as it is** (its keys still going
  through `:keys`). It used to be walked against its parent's properties.
- `:crypto` is listed in `extra_applications`, and `:telemetry` is an optional
  dependency, for the mapping cacher's keys and the failed-fetch event.

### Removed

- **Breaking:** named contexts — `config :dowser_client, contexts: [...]` is no
  longer read — and `Dowser.Client.Context.fetch/1`. A repo replaces both.
- **Breaking:** the `{:unknown_context, name}` error reason; a request now fails
  with `:no_repo`, `{:unknown_repo, name}` or `{:invalid_repo, repo, message}`.
## [0.3.1] - 2026-11-02

### Added

- **Compressed responses: `http_opts: [compressed: true]`.** `:httpc` neither
  asks for a compressed response nor decompresses one, so every response came
  over the wire as plain JSON. With the option, a request sends
  `accept-encoding: gzip` (unless it already names an encoding), and the
  response is decompressed before it is decoded, its `content-encoding` and
  `content-length` headers dropped with the compressed payload. A page of 100
  large search hits went from 4.2 MB to 568 KB, and from 8.7 s to 1.7 s over a
  VPN.

  A gzipped response is decompressed even when it wasn't asked for, and one
  whose body isn't valid gzip returns `{:error, :invalid_gzip_body}`. The option
  is off by default.

## [0.3.0] - 2026-09-25

### Changed

- **A retry can no longer repeat a write the server already applied.**
  `Dowser.Client.Retry` retried every failure it called transient, for every
  method — including a timeout or a `504`, where the request may well have been
  applied and only the answer was lost. A timed-out `POST /_bulk` or auto-id
  `POST /_doc` was re-sent, and the documents written twice.

  Failures are now classified by what they say about the request:

  | Failure | Retried |
  | --- | --- |
  | Never reached the server (`:econnrefused`, `:nxdomain`, `:enetunreach`, `:ehostunreach`, `{:failed_connect, _}`) | always |
  | Rejected by the server (`:retryable_statuses`, now `[429, 503]`) | always |
  | Ambiguous (`:timeout`, `:etimedout`, `:econnreset`, `:closed`, `:socket_closed_remotely`, and `:ambiguous_statuses`, `[502, 504]`) | only when idempotent |

  `:idempotent` defaults to the method (`GET`, `HEAD`, `PUT`, `DELETE`,
  `OPTIONS`, `TRACE` → `true`; `POST`, `PATCH` → `false`) and is overridable
  per request, which is how a read that happens to be a `POST` keeps its
  retries:

  ```elixir
  Dowser.Client.request(:post, "/_search", query, retry: [idempotent: true])
  ```

  `502` and `504` moved out of `:retryable_statuses` into the new
  `:ambiguous_statuses`, so the default policy retries fewer things for a
  non-idempotent request and exactly as many for an idempotent one.

### Added

- **`Retry-After` is obeyed.** A `429`/`503` that names a delay — in seconds or
  as an HTTP date — is waited out as asked rather than on the computed backoff,
  up to `:max_retry_after_ms` (default `60_000`), past which the request gives
  up instead of sleeping. Turn it off with `respect_retry_after: false`.

- **`:max_elapsed_ms`**, a wall-clock budget for the whole request (default
  `nil`, no budget). Three attempts two seconds apart is the wrong shape for a
  `429` burst; a budget bounds what the caller waits for, however many attempts
  the policy allows.

- `Dowser.Client.Retry.ambiguous?/1`, which says whether a failure leaves it
  unknown that the request was applied.

- `Dowser.Client.Retry.resolve/2` takes the request method, to derive
  `:idempotent`. The one-argument form still works and assumes a
  non-idempotent request.

## [0.2.1] - 2026-09-20

Maintenance release. No API or behavior changes.

### Fixed

- Dropped the stale `poison` entry left in `mix.lock` by the 0.2.0 dependency
  removal. It never reached users — `mix.lock` is not part of the published
  package — but it made `mix deps.get` fetch a dependency the project no longer
  declares.

## [0.2.0] - 2026-09-20

`dowser_client` now has **no dependencies at all**, optional ones included, and
one code path per job instead of three.

Every search backend it targets speaks HTTP/1.1, which is exactly what OTP's
`:httpc` does, and Elixir ships a `JSON` module — so the pluggable HTTP and JSON
adapters bought customization nobody needed at the cost of code paths to keep
working. In their place: one `:httpc` transport with real connection management
and TLS, and one pair of hooks for the casting only a backend package can do.

This is a breaking release. Every removal below is a compile- or request-time
error rather than a silent behavior change, and each entry names its replacement.

### Added

- `Dowser.Client.HTTP` — the transport, `:httpc` only. Flat `:http_opts`
  (`:connect_timeout` 2s, `:timeout` 30s, `:ssl`, `:autoredirect`, ...) instead
  of `:httpc`'s nested `HTTPOptions`/`Options` lists, with
  `http_opts: [http_options: [...], options: [...]]` as escape hatches merged
  last. An unrecognized key is an error (`{:unknown_http_opts, keys}`) rather
  than a silently ignored setting.
- `Dowser.Client.HTTP.Profile` — requests go through a dedicated `:httpc`
  profile (`:dowser_client` by default) instead of `:httpc`'s shared `:default`
  one, so connection pools, session settings and cookies are never shared with
  the rest of the application. `:profile` and `:profile_opts` (per request, per
  context, or global) name the profile and its `:httpc.set_options/2` settings —
  `max_sessions`, `max_keep_alive_length`, `keep_alive_timeout`,
  `pipeline_timeout`, `cookies`, `proxy`, ... Profiles start on demand and are
  configured once; the defaults are tuned for a search cluster
  (`max_sessions: 20`, `max_keep_alive_length: 100`,
  `keep_alive_timeout: 120_000`, `cookies: :disabled`). `Profile.info/1` reports
  `:httpc`'s own view of a profile, `Profile.reset/2` re-applies options at
  runtime, and `profile: :default` still opts into `:httpc`'s shared profile.
- `Dowser.Client.HTTP.SSL` — TLS for an `https://` endpoint, secure by default:
  chain verification against the OS trust store (`:public_key.cacerts_get/0`),
  certificate identity checked against the URL host, SNI, TLS 1.2+, depth 3.
  `http_opts: [ssl: [...]]` adjusts it — `insecure: true` for a `localhost`
  cluster with a self-signed certificate, `verify_hostname: false` for an SSH
  tunnel or port-forward where the hostname can never match,
  `:cacerts`/`:cacertfile` for a private CA, `:sni`, `:versions`, `:depth` — and
  any other key reaches `:ssl` verbatim. An IP-address host keeps its identity
  checked (against the certificate's IP SAN) even though SNI cannot carry one.
- `Dowser.Client.JSON` — `encode/1` to `iodata`, `decode/1` to string-keyed
  terms, both returning a `Dowser.Client.JSON.Error` rather than raising.
- `Dowser.Client.NDJSON.encode/2` and `decode/2` take the casting options and
  apply them **per entry**, since a line is the unit of an ndjson payload: an
  encoder sees one entry at a time (so a bulk encoder can pass action lines
  through and cast only documents), an `:encode` path applies within each entry,
  and a decoder is called with each decoded line. A body that isn't a list is
  `{:error, %Dowser.Client.Error{reason: {:invalid_ndjson, body}}}` rather than a
  raised `FunctionClauseError`.
- `Dowser.Client.Decoder` — the optional second pass over a decoded response
  body, since casting one needs to know where documents sit in the envelope and
  which index each came from, which is knowledge only a backend package has:
  - `:keys` — `:strings` (default, no casting), `:atoms`, `:atoms!`, or any
    `(String.t() -> term)` function. Applied on its own, through
    `Dowser.CoreExt.Keyable`, when there is no `:decoder`.
  - `:decoder` — a module exporting `decode/2`, a `(body, opts -> term)`
    function, or either paired with its options (`{MyDecoder, mapping: mapping}`).
    It receives the decoded body plus those options, `:key_fn` and `:context`,
    and owns the result — envelope walking, mapping lookups, field casting and
    key casting included.

  Both resolve per request, then from the context, then from
  `config :dowser_client, ...`; the most specific wins as a whole, options
  included. With neither set there is no second pass and a body stays exactly as
  JSON decoded it.
- `Dowser.Client.Encoder` — the mirror pass over a **document source** in a
  request body. Only a source is ever encoded: its fields are described by the
  mapping of the index it is going to, while a query has no such anchor (the
  same value means different things in a range clause, a script parameter, an
  aggregation boundary, a suggester), so a query body is never touched.
  - `:encoder` — same four shapes as `:decoder`, with `encode/2` as the module
    callback, and the same resolution across request, context and global.
  - `:encode` — where the source sits in this request's body: `false` (default),
    `true` (the body is the source), a path (`["doc"]` for a partial update), or
    a list of paths (`[["doc"], ["upsert"]]`). Per request only, since the call
    site is the only place that knows. A path is a list of `Access` keys
    (`["items", Access.at(0)]` reaches through a list-valued field), it applies
    within each entry of an ndjson body, and one pointing at nothing is skipped
    rather than created.
- Two more `:auth` shapes on a context, so a credential can be given either
  already encoded or as a pair: `{:basic, value}` sends `Basic <value>` and
  `{:api_key, id, api_key}` sends `ApiKey <base64("id:api_key")>`, alongside the
  existing `{:basic, username, password}`, `{:api_key, value}`,
  `{:bearer, token}` and `{:header, name, value}`.
- New `Dowser.Client.Error` reasons, so a misconfiguration is a result rather
  than a crash: `{:invalid_auth, auth}`, `{:invalid_keys, value}` (whose message
  suggests the nearest valid value for a typo — `:atom` → "did you mean
  :atoms?"), `{:invalid_decoder, value}`, `{:invalid_encoder, value}`,
  `{:invalid_encode, value}`, `{:decode_failed, exception}`,
  `{:encode_failed, exception}` and `{:removed_option, :http_adapter}`.
- `Dowser.CoreExt.Keyable` is documented rather than private: the key half of
  the response pass, for a decoder that casts a body's keys on its own. It also
  leaves non-binary keys alone instead of handing them to a key function that
  expects a binary.
- `Dowser.Client.Retry` also classifies `:socket_closed_remotely` (`:httpc`'s
  term for a keep-alive session the server closed under us), `:econnreset` and
  `:etimedout` as transient.
- `UPGRADE_GUIDE_0_2.md`, a step-by-step path from 0.1.1, shipped with the
  package and published with the docs.
- The library says so when a request carries an option 0.1.x understood:
  `:config` and `:http_adapter` are errors, since ignoring either could send the
  request somewhere the caller didn't ask for; `:codec_adapter`, `:codec_opts`,
  `:json_adapter` and `:json_opts` log a warning naming their replacement and
  the request proceeds.
- A typespec on every public function, and a `@type t` for
  `Dowser.Client.Context` and `Dowser.Client.Request`. `mix dialyzer` passes
  clean with `:error_handling`, `:extra_return`, `:missing_return` and
  `:unmatched_returns` enabled.

### Changed

- **Breaking.** A *config* is now a **context**, matching `elastic/cli`'s
  terminology for a named cluster:
  - `Dowser.Client.Config` → `Dowser.Client.Context` (same struct and
    `new/1`/`resolve/1`; `fetch_configuration/1` → `fetch/1`).
  - the `:config` request option → `:context`.
  - `config :dowser_client, configs: [...]` → `contexts: [...]`.
  - `{:unknown_config, name}` → `{:unknown_context, name}`.
- **Breaking.** A response body decodes to string-keyed maps and nothing else
  happens to it by default: `:keys` is no longer applied unless asked for. A
  request body is likewise encoded as given unless `:encode` points at a
  document source in it.
- **Breaking.** A `GET` carrying a body is sent as a `POST` on the same path
  (logged at debug level) instead of returning
  `{:error, {:unsupported_body, :get}}` — `:httpc`'s request tuple has no body
  slot for `GET`, and every backend that expects one (Elasticsearch's
  `GET /_search`) accepts the same request as a `POST`. A body on `HEAD`/`TRACE`,
  where it is meaningless, still returns `{:error, {:unsupported_body, method}}`.
- **Breaking.** `Dowser.Client.HTTP.Stub` is no longer an HTTP adapter and is no
  longer selected with `http_adapter: Dowser.Client.HTTP.Stub`: `stub/1`
  intercepts every request made by the calling process on its own, whatever the
  context. Drop `:http_adapter` from test contexts; everything else — the
  process-local state, `async: true` safety, `json/3`, `raw/3` — is unchanged.
  Added `clear/0` and `fetch/0`. A process with no stub no longer raises; it
  performs a real request.
- **Breaking.** `Dowser.Client.NDJSON.encode/3`/`decode/3` lose their
  adapter/options arguments and become `encode/1`/`decode/1`.
- **Breaking.** `Dowser.Client.HTTP.Error`'s `:adapter` field is now `:profile`.
- `:ssl`, `:profile_opts` and `:http_opts` merge per key across the global,
  context and request tiers, so overriding one TLS setting on a request no longer
  discards the trust store configured on the context.

### Removed

- **Breaking.** `Dowser.Client.HTTP.Adapter` and its implementations
  `Dowser.Client.HTTP.Httpc`, `Dowser.Client.HTTP.Req` and
  `Dowser.Client.HTTP.Hackney`, along with the `req` and `hackney` optional
  dependencies. HTTP is `Dowser.Client.HTTP` over `:httpc`, always.
- **Breaking.** The `:http_adapter` option, in all three tiers. A request still
  passing it fails with a `Dowser.Client.Error` naming the migration rather than
  quietly sending the request somewhere else; on a context it is ignored like any
  unknown key.
- **Breaking.** `Dowser.Client.JSON.Adapter` and its implementations
  `Dowser.Client.JSON.Native`, `Dowser.Client.JSON.Jason` and
  `Dowser.Client.JSON.Poison`, along with the `jason` and `poison` optional
  dependencies and the `:json_adapter`/`:json_opts` options. JSON is Elixir's
  built-in `JSON` module, always.
- **Breaking.** The whole codec layer: `Dowser.Client.Codec`,
  `Dowser.Client.Codec.Default`, `Dowser.Client.Codec.Error` and the
  `:codec_adapter`/`:codec_opts` options, replaced by `:keys`/`:decoder` for
  reading and `:encoder`/`:encode` for writing.
- **Breaking.** `Dowser.Client.Codec.Builder` and `Dowser.Client.Field`, the
  per-field casting layer. Nothing in `dowser_client` ever called them: the
  pipeline only knows a `:decoder` and an `:encoder`, and how to dispatch inside
  one is the backend package's business, not the transport's. Move them into
  yours — a `cast/2` dispatcher is a `use`-able macro and a behaviour, with no
  ties to this library — or write whatever suits that backend's mapping instead.
  `:formatter.exs`' `locals_without_parens: [cast: 2]` goes with them.
- **Breaking.** Both aliases deprecated in 0.1.1 are gone, as announced there —
  and so are the modules they delegated to: `Dowser.Client.CodecBuilder` (for
  `Dowser.Client.Codec.Builder`) and `Dowser.Client.Codecs.DefaultCodec` (for
  `Dowser.Client.Codec.Default`).

## [0.1.1] - 2026-08-17

### Changed

- Codec modules now live under the `Dowser.Client.Codec` namespace, for
  consistency with `Dowser.Client.HTTP.*` and `Dowser.Client.JSON.*`:
  `Dowser.Client.CodecBuilder` is now `Dowser.Client.Codec.Builder`, and
  `Dowser.Client.Codecs.DefaultCodec` — the default `:codec_adapter` — is now
  `Dowser.Client.Codec.Default`. Behavior is unchanged.

### Deprecated

- `Dowser.Client.CodecBuilder` — kept as an alias delegating to
  `Dowser.Client.Codec.Builder`; `use Dowser.Client.CodecBuilder` still works
  but now emits a deprecation warning at compile time. To be removed in a
  future release.
- `Dowser.Client.Codecs.DefaultCodec` — kept as an alias delegating to
  `Dowser.Client.Codec.Default`, so a config or request that names it
  explicitly as `:codec_adapter` keeps working. To be removed in a future
  release.

### Fixed

- The docs no longer reference the private `Dowser.CoreExt.Keyable` protocol,
  which made `mix docs` warn about documentation referencing a hidden
  function from the README, `Dowser.Client.Codec` and
  `Dowser.Client.Codec.Default`.

## [0.1.0] - 2026-08-17

Initial release.

### Added

- `Dowser.Client` — low-level entry point for querying a search backend over
  HTTP (`request/4`, plus `get/post/put/patch/delete` shortcuts). Resolves a
  config and request options, performs the HTTP call, retries transient
  failures, and decodes the response body.
- `Dowser.Client.Config` — bundles an `:endpoint`, `:auth`, and the HTTP/JSON/
  codec adapters and options to use for one search backend. Configs can be
  built inline with `new/1` or configured by name at compile time
  (`config :dowser_client, configs: [...]`) and resolved by atom, map/keyword
  list, or omitted entirely (resolves the `:default` named entry — there is
  no other built-in fallback). `inspect/1` redacts the `:auth` secret.
- Pluggable HTTP transport via `Dowser.Client.HTTP.Adapter`, with three
  bundled implementations, all pinned to HTTP/1.1 with keep-alive:
  - `Dowser.Client.HTTP.Httpc` — Erlang's built-in `:httpc` (no extra
    dependency), used by default.
  - `Dowser.Client.HTTP.Req` — the [`Req`](https://hex.pm/packages/req)
    library (optional dependency).
  - `Dowser.Client.HTTP.Hackney` — [`:hackney`](https://hex.pm/packages/hackney)
    (optional dependency).
  - Sensible default connect (2s) and receive (30s) timeouts on every
    adapter, always overridable per request via `:http_opts`.
  - Adapter selection honors runtime application config
    (`config :dowser_client, :http_adapter | :json_adapter | :codec_adapter`),
    not just compile-time settings.
- Automatic retries on transient failures — connection errors (refused,
  closed, timed out, unreachable) and retryable HTTP statuses (`429`, `502`,
  `503`, `504`) — with exponential backoff and full jitter. On by default for
  every request/method; configurable or disable-able via `:retry`.
- Pluggable JSON codec via `Dowser.Client.JSON.Adapter`, with three bundled
  implementations:
  - `Dowser.Client.JSON.Native` — Elixir's built-in `JSON` module (no extra
    dependency), used by default.
  - `Dowser.Client.JSON.Jason` — the [`Jason`](https://hex.pm/packages/jason)
    library (optional dependency).
  - `Dowser.Client.JSON.Poison` — the [`Poison`](https://hex.pm/packages/poison)
    library (optional dependency).
- Request/response body formats: `:json` (default), `:ndjson` for bulk-style
  newline-delimited payloads, and `:raw` to pass bytes through untouched;
  `:req_format`/`:resp_format` set each direction independently.
- `Dowser.Client.Field` — a behaviour for casting a single value to and from
  its wire representation (`load/2`/`dump/2`), for the backend-specific
  knowledge `dowser_client` doesn't have; backend packages like
  `dowser_elasticsearch` ship their own field implementations.
- `Dowser.Client.CodecBuilder` — `use`-able macro that builds a `load/2`/
  `dump/2` dispatcher from a list of `Dowser.Client.Field` mappings declared
  with `cast/2`, pattern-matched against field metadata. Expands to plain
  pattern-matched function clauses at compile time, with `:inherit`,
  `:fallback` and `:nil` options.
- `Dowser.Client.Codec` — a behaviour for casting a whole request/response
  body (`encode/2`/`decode/2`), wired onto a config/request as
  `:codec_adapter`. `Dowser.Client.Codecs.DefaultCodec` is the built-in
  default, applying only `:keys` casting; a backend package composes its own
  `Codec` on top of a `CodecBuilder`-built dispatcher for per-field value
  casting (dates, geo points, ...), and `:codec_opts` (settable as a
  `Dowser.Client.Config` default and per-request overridable) is forwarded to
  it.
- `:keys` (`:strings` default, `:atoms`, `:atoms!`) to cast a decoded body's
  keys — however deeply nested — resolved into a `:key_fn` passed to
  `:codec_adapter`; settable as a `Dowser.Client.Config` default and
  per-request overridable.
- Authentication helpers on `Dowser.Client.Config` for `:basic`, `:bearer`,
  `:api_key`, and arbitrary `:header` auth, applied as request headers.
- Header merging across global (`config :dowser_client, :http_opts,
  headers: ...`), config, and per-request sources, with later (more
  specific) sources winning on name clashes.
- Normalized error types so callers never see a dependency's own exception:
  `Dowser.Client.Error` (config resolution, invalid `:format`/`:keys`/
  `:retry`, missing optional adapter dependency), `Dowser.Client.JSON.Error`
  (encode/decode failures), `Dowser.Client.Codec.Error` (`:codec_adapter`
  `encode/2`/`decode/2` failures), and `Dowser.Client.HTTP.Error` (transport
  failures, reported with the number of attempts made).
- `Dowser.unwrap/1` to unwrap a `{:ok, value} | {:error, exception}` result
  into the plain value or a raised exception.
- `Dowser.Client.HTTP.Stub` — a fourth `HTTP.Adapter` for tests. `stub/1`
  scripts the response for every request made by the calling process (no
  shared/global state, safe under `async: true`), and `json/3`/`raw/3` build
  matching responses, so a test can drive the full request/response pipeline
  without a real backend running.

### Known limitations

- `Dowser.Client.HTTP.Httpc` cannot send a request body on `GET`/`HEAD`/
  `TRACE` (Erlang's `:httpc` has no body slot for those methods) — it returns
  `{:error, {:unsupported_body, method}}` rather than silently dropping the
  body. Backends that expect a body on `GET` (e.g. Elasticsearch's
  `GET /_search`) need `Dowser.Client.HTTP.Req` or `Dowser.Client.HTTP.Hackney`.
