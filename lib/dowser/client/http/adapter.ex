defmodule Dowser.Client.HTTP.Adapter do
  @moduledoc """
  Behaviour implemented by every HTTP transport (`:httpc`, `Req`, `:hackney`).

  Adapters are pure transport: given a fully-resolved request, they perform it
  and return a normalized `Dowser.Client.Response` (or an error). They do
  not encode/decode bodies — that is the JSON layer's job.

  The `url` is expected to be a complete, absolute URL (endpoint + path +
  query string already joined). `headers` are string tuples. `body` is raw
  `iodata` or `nil`. `opts` are adapter-specific passthrough options; see each
  adapter's docs for the keys it understands.

  Bundled implementations:

    * `Dowser.Client.HTTP.Httpc` — OTP `:httpc` (no extra dependency)
    * `Dowser.Client.HTTP.Req` — the `Req` library (optional dependency)
    * `Dowser.Client.HTTP.Hackney` — `:hackney` (optional dependency)
    * `Dowser.Client.HTTP.Stub` — scriptable stub for tests (no extra
      dependency)
  """

  alias Dowser.Client.Response

  ## Typespecs

  @type method :: :get | :post | :put | :patch | :delete | :head | :options
  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type body :: iodata() | nil
  @type opts :: keyword()

  ## Behaviour callbacks

  @callback request(method(), url(), headers(), body(), opts()) ::
              {:ok, Response.t()} | {:error, term()}
end
