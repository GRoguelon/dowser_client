defmodule Dowser.Client.HTTP do
  @moduledoc """
  The HTTP transport: OTP's `:httpc`, and nothing else.

  Given a method, an absolute URL, headers and an already-encoded body, it
  performs the request and returns a normalized `Dowser.Client.Response` (or an
  error). It never encodes or decodes bodies — that is the JSON/codec layer's
  job.

  `:httpc` ships with OTP, so `dowser_client` has no HTTP dependency at all.
  Every request is HTTP/1.1 with keep-alive, sent through a dedicated
  `:httpc` profile (see `Dowser.Client.HTTP.Profile`) rather than the shared
  `:default` one.

  ## Options

  `:http_opts`, merged global → context → request, is passed here:

    * `:connect_timeout` — TCP connect timeout in milliseconds; default `2_000`.
    * `:timeout` — whole-request timeout in milliseconds; default `30_000`.
    * `:ssl` — TLS options for an `https://` endpoint; see
      `Dowser.Client.HTTP.SSL`. Verification is on by default.
    * `:profile` / `:profile_opts` — the `:httpc` profile to send through and
      its `:httpc.set_options/2` settings (`max_sessions`,
      `max_keep_alive_length`, `keep_alive_timeout`, `pipeline_timeout`,
      `cookies`, ...); see `Dowser.Client.HTTP.Profile`.
    * `:autoredirect`, `:proxy_auth`, `:relaxed` — passed to `:httpc` as
      `HTTPOptions`.
    * `:full_result`, `:headers_as_is`, `:socket_opts`, `:ipv6_host_with_brackets`
      — passed to `:httpc` as `Options`.
    * `:http_options` / `:options` — escape hatches merged last into `:httpc`'s
      two option lists, for anything not named above.

  An unrecognized key is an error (`{:unknown_http_opts, keys}`) rather than a
  silently ignored setting.

  `version: ~c"HTTP/1.1"` and `body_format: :binary` are always set: `:httpc`
  never speaks HTTP/2, and the response body always comes back as a binary.

  ## `GET` with a body

  `:httpc`'s request tuple has no body slot for `:get`, `:head` or `:trace`.
  Since search backends do expect a body on `GET` (Elasticsearch's
  `GET /_search`), a `:get` carrying a non-empty body is sent as a `POST` —
  which every such backend accepts on the same path — and logged at debug
  level. A body on `:head`/`:trace` is meaningless, so it returns
  `{:error, {:unsupported_body, method}}` rather than being dropped silently.

  ## Testing

  `Dowser.Client.HTTP.Stub.stub/1` intercepts requests in the calling process,
  so tests exercise the whole pipeline without a server. Checked first on every
  request, which costs one process-dictionary read in production.
  """

  require Logger

  alias Dowser.Client.HTTP.Profile
  alias Dowser.Client.HTTP.SSL
  alias Dowser.Client.HTTP.Stub
  alias Dowser.Client.Response

  ## Typespecs

  @type method :: :get | :post | :put | :patch | :delete | :head | :options | :trace
  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type body :: iodata() | nil
  @type opts :: keyword()

  ## Module attributes

  # The methods :httpc's request tuple has a body slot for.
  @body_methods [:post, :put, :patch, :delete, :options]

  @http_options_keys [:timeout, :connect_timeout, :autoredirect, :proxy_auth, :relaxed]

  @options_keys [:full_result, :headers_as_is, :socket_opts, :ipv6_host_with_brackets]

  @default_content_type "application/json"

  @default_connect_timeout 2_000

  @default_timeout 30_000

  ## Public functions

  @doc """
  Performs `method` against `url`, returning `{:ok, %Dowser.Client.Response{}}`
  for any completed exchange (whatever the status), or `{:error, reason}` when
  the transport fails.

  `reason` is `:httpc`'s own term (`:timeout`, a `{:failed_connect, _}` tuple,
  ...) or one of this layer's: `{:unsupported_body, method}`,
  `{:unknown_http_opts, keys}`, `{:no_cacerts, _}`, `{:profile_down, _}`.
  `Dowser.Client` wraps it in a `Dowser.Client.HTTP.Error`.
  """
  @spec request(method(), url(), headers(), body(), opts()) ::
          {:ok, Response.t()} | {:error, term()}
  def request(method, url, headers, body, opts \\ []) do
    case Stub.fetch() do
      {:ok, fun} -> fun.(method, url, headers, body, opts)
      :error -> perform(method, url, headers, body, opts)
    end
  end

  ## Private functions

  defp perform(method, url, headers, body, opts) do
    {profile, profile_opts, opts} = pop_profile(opts)
    {method, body} = resolve_method(method, body, url)

    with {:ok, profile} <- Profile.ensure_started(profile, profile_opts),
         {:ok, http_options, options} <- split_opts(url, opts),
         {:ok, request} <- build_request(method, url, headers, body) do
      send_request(method, request, http_options, options, profile)
    end
  end

  defp pop_profile(opts) do
    {profile, opts} = Keyword.pop(opts, :profile)
    {profile_opts, opts} = Keyword.pop(opts, :profile_opts, [])

    {profile || Profile.default(), profile_opts, opts}
  end

  defp send_request(method, request, http_options, options, profile) do
    case :httpc.request(method, request, http_options, options, profile) do
      {:ok, {{_version, status, _reason}, headers, body}} ->
        {:ok, Response.new(status, headers, to_binary(body))}

      # `full_result: false`
      {:ok, {status, body}} ->
        {:ok, Response.new(status, [], to_binary(body))}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_result, other}}
    end
  catch
    # The profile manager is gone (crashed, or inets was restarted): forget it
    # so the next request starts and configures a fresh one.
    :exit, reason ->
      Profile.invalidate(profile)

      {:error, {:profile_down, reason}}
  end

  ## Private functions — method & body

  # `:httpc` has no body slot for `:get`, but search backends expect one
  # (`GET /_search`), and all of them accept the same request as a `POST`.
  defp resolve_method(:get, body, url) do
    if empty_body?(body) do
      {:get, nil}
    else
      Logger.debug(fn ->
        "Dowser.Client.HTTP: GET #{url} carries a body, sending it as POST (:httpc " <>
          "has no request body for GET)"
      end)

      {:post, body}
    end
  end

  defp resolve_method(method, body, _url) do
    if empty_body?(body), do: {method, nil}, else: {method, body}
  end

  defp empty_body?(nil), do: true

  defp empty_body?(body) do
    IO.iodata_length(body) == 0
  rescue
    # Not iodata at all (a `:raw` body that was never encoded): leave it to
    # `:httpc` to reject, rather than reporting it as an empty body here.
    ArgumentError -> false
  end

  defp build_request(method, url, headers, body) when method in @body_methods do
    {content_type, rest} = pop_content_type(headers)

    {:ok, {to_charlist(url), encode_headers(rest), to_charlist(content_type), body || ""}}
  end

  defp build_request(_method, url, headers, nil) do
    {:ok, {to_charlist(url), encode_headers(headers)}}
  end

  defp build_request(method, _url, _headers, _body) do
    {:error, {:unsupported_body, method}}
  end

  # :httpc takes the content type as its own tuple element, not as a header.
  defp pop_content_type(headers) do
    case Enum.split_with(headers, fn {name, _value} ->
           String.downcase(name) == "content-type"
         end) do
      {[{_name, value} | _rest], rest} -> {value, rest}
      {[], rest} -> {@default_content_type, rest}
    end
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: IO.iodata_to_binary(body)

  ## Private functions — options

  defp split_opts(url, opts) do
    {ssl_opts, opts} = Keyword.pop(opts, :ssl, [])
    {http_options_extra, opts} = Keyword.pop(opts, :http_options, [])
    {options_extra, opts} = Keyword.pop(opts, :options, [])

    with :ok <- validate_opts(opts),
         {:ok, ssl} <- SSL.options(url, ssl_opts) do
      http_options =
        opts
        |> Keyword.take(@http_options_keys)
        |> Keyword.put_new(:connect_timeout, @default_connect_timeout)
        |> Keyword.put_new(:timeout, @default_timeout)
        |> put_ssl(ssl)
        |> Keyword.merge(http_options_extra)
        |> Keyword.put(:version, ~c"HTTP/1.1")

      options =
        opts
        |> Keyword.take(@options_keys)
        |> Keyword.merge(options_extra)
        |> Keyword.put(:body_format, :binary)

      {:ok, http_options, options}
    end
  end

  defp validate_opts(opts) do
    case Keyword.drop(opts, @http_options_keys ++ @options_keys) do
      [] -> :ok
      unknown -> {:error, {:unknown_http_opts, Keyword.keys(unknown)}}
    end
  end

  defp put_ssl(http_options, nil), do: http_options
  defp put_ssl(http_options, ssl), do: Keyword.put(http_options, :ssl, ssl)
end
