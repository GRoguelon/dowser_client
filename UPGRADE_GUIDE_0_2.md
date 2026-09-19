# Upgrading from 0.1.1 to 0.2.0

0.2.0 drops every optional dependency and every pluggable adapter: HTTP is OTP's
`:httpc`, JSON is Elixir's `JSON`, and the casting layer is two functions the
backend package supplies. This guide is the mechanical path from 0.1.1.

Work through it with the table first — most upgrades are a rename — then read
[Watch out for silence](#watch-out-for-silence), which is the one part the
compiler cannot help you with.

## At a glance

| 0.1.1 | 0.2.0 |
| --- | --- |
| `Dowser.Client.Config` | `Dowser.Client.Context` |
| `Config.fetch_configuration/1` | `Context.fetch/1` |
| `config :dowser_client, configs: [...]` | `contexts: [...]` |
| `config: ...` request option | `context: ...` |
| `{:unknown_config, name}` | `{:unknown_context, name}` |
| `:http_adapter` (+ `HTTP.Httpc`/`Req`/`Hackney`) | nothing — `Dowser.Client.HTTP` over `:httpc` |
| `http_opts: [http_options: [timeout: t]]` | `http_opts: [timeout: t]` |
| `:json_adapter`, `:json_opts` (+ `JSON.Native`/`Jason`/`Poison`) | nothing — `Dowser.Client.JSON` |
| `:codec_adapter`, `:codec_opts` | `:decoder` (reading), `:encoder` + `:encode` (writing) |
| `Dowser.Client.Codec`, `Codec.Default`, `Codec.Error` | removed |
| `Dowser.Client.CodecBuilder` | `Dowser.Client.Codec.Builder` |
| `Dowser.Client.Codecs.DefaultCodec` | removed |
| `http_adapter: Dowser.Client.HTTP.Stub` | nothing — `Stub.stub/1` intercepts on its own |
| `HTTP.Error`'s `:adapter` | `:profile` |
| `NDJSON.encode/3`, `NDJSON.decode/3` | `encode/2`, `decode/2` |

## 1. Dependencies

Remove whatever you added for `dowser_client` — `req`, `hackney`, `jason`,
`poison`. Nothing replaces them. If your application uses those libraries for its
own reasons, keep them; `dowser_client` no longer looks at them either way.

`:inets` and `:ssl` are already in this package's `extra_applications`, so
there is nothing to start yourself.

0.2.0 needs Elixir 1.18+ (for the built-in `JSON` module) and OTP 25+ (for
`:public_key.cacerts_get/0`, which TLS verification uses).

## 2. Configs are contexts

```diff
  config :dowser_client,
-   configs: [
+   contexts: [
      default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}]
    ]

- Dowser.Client.get("/_search", config: :logs)
+ Dowser.Client.get("/_search", context: :logs)

- {:error, %Dowser.Client.Error{reason: {:unknown_config, :logs}}}
+ {:error, %Dowser.Client.Error{reason: {:unknown_context, :logs}}}
```

`Dowser.Client.Config` → `Dowser.Client.Context`, same struct and same
`new/1`/`resolve/1`; `fetch_configuration/1` is now `fetch/1`.

Two `:auth` shapes were added, so a credential can be given already encoded or
as a pair — nothing existing changed:

```elixir
{:basic, "dXNlcjpwYXNz"}      # new: Basic <value>, already encoded
{:api_key, "id", "api_key"}   # new: ApiKey <base64("id:api_key")>
```

An unrecognized `:auth` used to crash with a `FunctionClauseError`; it is now
`{:error, %Dowser.Client.Error{reason: {:invalid_auth, auth}}}`.

## 3. The HTTP adapter is gone

Drop `:http_adapter` everywhere. A request that still passes it fails with a
`Dowser.Client.Error` naming this guide, so you will find those call sites; on a
context it is ignored like any unknown key, so **grep for it there**.

`:http_opts` is now flat — no nested `:http_options`/`:options`:

```diff
- http_opts: [http_options: [connect_timeout: 1_000, timeout: 5_000]]
+ http_opts: [connect_timeout: 1_000, timeout: 5_000]
```

An unrecognized `:http_opts` key is now an error (`{:unknown_http_opts, keys}`),
which is how you will find anything adapter-specific left behind —
`:recv_timeout` (hackney), `:receive_timeout`/`:connect_options` (Req), and so
on. `http_opts: [http_options: [...], options: [...]]` still works as an escape
hatch for anything `:httpc` accepts that isn't named.

Two things that were adapter differences are now settled behaviour:

- **A `GET` carrying a body is sent as a `POST`** on the same path, since
  `:httpc` has no body slot for `GET`. If you worked around
  `{:error, {:unsupported_body, :get}}` by rewriting the call to `POST`
  yourself, you can undo that. A body on `HEAD`/`TRACE` still errors.
- **Requests go through a `:dowser_client` `:httpc` profile**, not the shared
  `:default` one, so connection pooling and cookies are isolated from the rest
  of your application. Give a cluster its own with `profile: :name`, and tune it
  with `:profile_opts`; see `Dowser.Client.HTTP.Profile`.

If you talk to an `https://` endpoint, TLS is now verified by default (OS trust
store, hostname check, TLS 1.2+). A self-signed or tunnelled cluster that used to
connect may now refuse to:

```elixir
# localhost with a self-signed certificate
http_opts: [ssl: [insecure: true]]

# SSH tunnel or port-forward: real CA, hostname can never match
http_opts: [ssl: [verify_hostname: false]]

# a private CA
http_opts: [ssl: [cacertfile: "/etc/ssl/certs/internal-ca.pem"]]
```

## 4. The JSON adapter is gone

Drop `:json_adapter` and `:json_opts`. Bodies are encoded and decoded by
`Dowser.Client.JSON` over Elixir's `JSON`.

Two consequences worth checking:

- **`Jason`'s `@derive Jason.Encoder` no longer applies.** A struct in a request
  body now needs `@derive JSON.Encoder` instead, or it raises
  `Protocol.UndefinedError` — which comes back as
  `{:error, %Dowser.Client.JSON.Error{operation: :encode}}`. `Date`, `Time`,
  `NaiveDateTime` and `DateTime` already encode themselves as ISO 8601.
- `Dowser.Client.NDJSON.encode/3`/`decode/3` lost their adapter and options
  arguments: they are `encode/2` and `decode/2`, and the second argument is now
  the casting options (below).

## 5. Codecs become a decoder and an encoder

This is the substantial change. `:codec_adapter` cast a whole body in both
directions; 0.2.0 splits that in two, because the two directions need different
information.

**Reading.** A response body decodes to plain, string-keyed terms and stops
there. `:keys` casts keys; `:decoder` owns everything else:

```diff
- Dowser.Client.get("/articles/_search", codec_adapter: MyApp.Codec, keys: :atoms)
+ Dowser.Client.get("/articles/_search", decoder: MyApp.Decoder, keys: :atoms)
```

Your old `Codec.decode/2` becomes a `decode/2` that takes the body and an option
list, and owns the result — including applying `opts[:key_fn]`, since
`dowser_client` no longer casts keys around it:

```elixir
defmodule MyApp.Decoder do
  def decode(body, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)

    # walk your own envelope, resolve your own mappings, cast your own fields
    do_decode(body, key_fn)
  end
end
```

`:codec_opts` is gone: whatever the decoder needs travels with it, and
`:context` is always added:

```diff
- decoder: MyApp.Decoder, codec_opts: [mapping: mapping]
+ decoder: {MyApp.Decoder, mapping: mapping}
```

Without a `:decoder`, `:keys` is applied on its own through
`Dowser.CoreExt.Keyable`. **With neither, nothing happens to the body at all** —
`:keys` used to be applied by the default codec, and now it is not applied unless
you ask. If you relied on `keys: :atoms` implicitly, pass it.

**Writing.** Only a document source is encoded, never a query — a query has no
mapping to anchor it. So the encoder runs when a request says where the source
is:

```diff
- Dowser.Client.put("/articles/_doc/1", document, codec_adapter: MyApp.Codec)
+ Dowser.Client.put("/articles/_doc/1", document,
+   encoder: {MyApp.Encoder, index: "articles"},
+   encode: true
+ )
```

`:encode` says where: `true` (the body is the source), a path (`["doc"]` for a
partial update), or a list of paths (`[["doc"], ["upsert"]]`). Without it nothing
is encoded, so **search bodies are never touched** — if your old codec cast query
values, that casting has to move into how you build the query.

Your old `Codec.encode/2` becomes an `encode/2` over one source.

**Per-field casting is unchanged.** `Dowser.Client.Field` and
`Dowser.Client.Codec.Builder` stay exactly as they were: they are what a decoder
and encoder dispatch into, field by field. Only the deprecated
`Dowser.Client.CodecBuilder` alias is gone — `use Dowser.Client.Codec.Builder`.

**An `:ndjson` payload is cast per line**, in both directions, because a line is
the unit of a bulk or multi-search body. An encoder sees one entry at a time, so
it can pass action lines through:

```elixir
def encode(%{"index" => _action} = line, _opts), do: line
def encode(document, opts), do: cast(document, opts[:index])
```

## 6. Tests

`Dowser.Client.HTTP.Stub` is no longer an adapter, so nothing points at it:

```diff
- config = Dowser.Client.Config.new(endpoint: "http://x:9200", http_adapter: Dowser.Client.HTTP.Stub)
- Dowser.Client.put("/i/_doc/1", doc, config: config)
+ Dowser.Client.put("/i/_doc/1", doc, context: [endpoint: "http://x:9200"])
```

`stub/1` intercepts every request made by the calling process on its own,
whatever the context — but the context is still resolved, so a test needs one
(the configured `:default` or an inline one). A process with **no** stub no
longer raises; it performs a real request, so a test that forgets `stub/1` will
try to reach the network.

`clear/0` removes a stub; `json/3` and `raw/3` are unchanged.

## Watch out for silence

Options removed in 0.2.0 are **ignored, not rejected** (except `:http_adapter`).
A request carrying one of these is accepted and simply does not do what you
meant:

```
:codec_adapter   :codec_opts   :json_adapter   :json_opts
```

Grep for them before you upgrade, and for `config:`/`configs:` which are now
`context:`/`contexts:`. The same applies to a plain typo (`keyz: :atoms`), so it
is worth a search rather than a test run.

## Checklist

- [ ] Remove `req`, `hackney`, `jason`, `poison` from `deps` if they were there
      only for `dowser_client`.
- [ ] `configs:` → `contexts:`, `config:` → `context:`,
      `Dowser.Client.Config` → `Dowser.Client.Context`.
- [ ] Delete every `:http_adapter`, and flatten `http_opts[:http_options]`.
- [ ] Delete every `:json_adapter`/`:json_opts`; add `@derive JSON.Encoder` to
      structs you send.
- [ ] Replace `:codec_adapter`/`:codec_opts` with `:decoder` and with
      `:encoder` + `:encode`; move key casting into the decoder.
- [ ] Pass `keys:` explicitly wherever you relied on the old default codec.
- [ ] Drop `http_adapter: Stub` from tests, and give each stubbed test a context.
- [ ] For an `https://` endpoint, decide between real verification and
      `ssl: [insecure: true]`/`[verify_hostname: false]`.
- [ ] Run the suite with `mix test`, then grep for the names under
      [Watch out for silence](#watch-out-for-silence).
