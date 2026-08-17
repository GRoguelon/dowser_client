# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
