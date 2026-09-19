defmodule Dowser.Client.Request do
  @moduledoc """
  A fully-resolved HTTP request, ready to hand to `Dowser.Client.HTTP`.

  `new/5` turns a `Dowser.Client.Context` plus a method, path, body and
  per-request options into a `%Request{}`. All option resolution happens here,
  so the transport only ever sees a finished request:

    * **headers** — merge of global (`config :dowser_client, :http_opts,
      headers: ...`), context (`auth` + context `http_opts[:headers]`) and
      per-request (`opts[:http_opts][:headers]`) headers, plus a
      `content-type` derived from the request format. Later sources win on
      name clashes. Each source accepts either a map or a list of
      `{name, value}` pairs.
    * **url** — the context's endpoint joined with the request path and, when
      given, `opts[:params]` encoded as a query string. An absolute path is
      used verbatim.
    * **body** — a document source in it cast through `:encoder` when `:encode`
      says where (see Casting below), then encoded according to the request
      format (`:json`, `:ndjson` or `:raw`) by
      `Dowser.Client.JSON`/`Dowser.Client.NDJSON`.
    * **http_opts** — `:http_opts` merged global → context → request (minus
      `:headers`, kept as its own field — see above), plus the resolved
      `:profile` and `:profile_opts`. Handed straight to
      `Dowser.Client.HTTP.request/5`.
    * **retry** — the resolved retry policy, from `opts[:retry]`; see
      `Dowser.Client.Retry`.

  ## Formats

  The request and response bodies each have a format (`:json`, `:ndjson` or
  `:raw`), resolved from the options:

    * `:format` — sets both, and is mutually exclusive with `:req_format` /
      `:resp_format`. Defaults to `:json`.
    * `:req_format` / `:resp_format` — set each direction independently; a
      missing one falls back to `:format` (so `:json`).

  ## Casting

  A response body always decodes to plain, string-keyed terms. `:keys` and
  `:decoder` — resolved here into the `:key_fn` and `:decoder` fields, each
  falling back to the context's value then to `config :dowser_client, ...` —
  configure the optional second pass over it; see `Dowser.Client.Decoder`.
  Neither set means no second pass at all.

  A request body is encoded as given unless `:encode` points at a document
  source in it, in which case `:encoder` — the encoder and the options it needs —
  casts that source; a query is never touched. See `Dowser.Client.Encoder`.

  The second pass is skipped when the format is `:raw` or the body is empty.
  """

  require Logger

  alias Dowser.Client.Context
  alias Dowser.Client.Decoder
  alias Dowser.Client.Encoder
  alias Dowser.Client.Error
  alias Dowser.Client.Headers
  alias Dowser.Client.HTTP
  alias Dowser.Client.HTTP.Profile
  alias Dowser.Client.JSON
  alias Dowser.Client.NDJSON
  alias Dowser.Client.Retry

  ## Structure

  defstruct [
    :key_fn,
    :decoder,
    :http_opts,
    :resp_format,
    :url,
    :method,
    :headers,
    :body,
    :retry
  ]

  ## Typespecs

  @type format :: :json | :ndjson | :raw

  @type t :: %__MODULE__{
          key_fn: Decoder.key_fun() | nil,
          decoder: Decoder.resolved() | nil,
          http_opts: keyword(),
          resp_format: format(),
          url: String.t(),
          method: HTTP.method(),
          headers: HTTP.headers(),
          body: HTTP.body(),
          retry: Retry.config()
        }

  ## Module attributes

  @formats [:json, :ndjson, :raw]

  @json_mime_type "application/json"
  @ndjson_mime_type "application/x-ndjson"

  ## Public functions

  @doc """
  Resolves a context plus a method, path, body and options into a `%Request{}`.

  Returns `{:error, exception}` for an invalid option, an unsupported body, or a
  `:decoder`/`:encoder` that raised — never raises, whatever those do.
  """
  @spec new(Context.t(), HTTP.method(), String.t() | nil, term(), keyword()) ::
          {:ok, t()} | {:error, Exception.t()}
  def new(context, method, path, body, opts) do
    with :ok <- reject_removed_opts(opts),
         :ok <- validate_auth(context.auth),
         {:ok, {req_format, resp_format}} <- fetch_formats(opts),
         {:ok, key_fn} <- fetch_key_fn(context, opts),
         {:ok, decoder} <- fetch_decoder(context, opts),
         {:ok, encoder} <- fetch_encoder(context, opts),
         {:ok, encode} <- fetch_encode(opts),
         {:ok, retry} <- Retry.resolve(opts),
         {:ok, encoded_body} <-
           encode_body(body, req_format, encoder, encode) do
      {http_opts, headers} = resolve_http_opts(context, req_format, resp_format, opts)
      query_params = Keyword.get(opts, :params)

      request = %__MODULE__{
        url: build_url(context.endpoint, path, query_params),
        method: method,
        headers: headers,
        body: encoded_body,
        retry: retry,
        http_opts: http_opts,
        resp_format: resp_format,
        key_fn: key_fn,
        decoder: decoder
      }

      {:ok, request}
    end
  end

  @doc "Performs the request over `Dowser.Client.HTTP`."
  @spec run(t()) :: {:ok, Dowser.Client.Response.t()} | {:error, term()}
  def run(%__MODULE__{} = request) do
    HTTP.request(
      request.method,
      request.url,
      request.headers,
      request.body,
      request.http_opts
    )
  end

  ## Private functions — removed options

  # Options 0.1.x understood and 0.2.0 does not. Two of them name *where* a
  # request goes, so ignoring one would quietly send it somewhere the caller
  # didn't ask for — those are errors. The rest only shape a body, so they warn
  # and the request proceeds; see UPGRADE_GUIDE_0_2.md.
  @rejected_options [:config, :http_adapter]

  @deprecated_options [:codec_adapter, :codec_opts, :json_adapter, :json_opts]

  defp reject_removed_opts(opts) do
    case Enum.find(@rejected_options, &Keyword.has_key?(opts, &1)) do
      nil -> warn_removed_opts(opts)
      option -> {:error, %Error{reason: {:removed_option, option}}}
    end
  end

  defp warn_removed_opts(opts) do
    @deprecated_options
    |> Enum.filter(&Keyword.has_key?(opts, &1))
    |> Enum.each(&warn_removed_opt/1)
  end

  defp warn_removed_opt(option) do
    Logger.warning(fn ->
      "Dowser.Client: #{inspect(option)} was removed in 0.2.0 and is ignored — " <>
        Error.removed_option_hint(option) <> ". See UPGRADE_GUIDE_0_2.md."
    end)
  end

  ## Private functions — format & body

  # `:format` sets both directions and is mutually exclusive with
  # `:req_format` / `:resp_format`; each of those falls back to `:format`
  # (default `:json`) when absent.
  defp fetch_formats(opts) do
    if format = Keyword.get(opts, :format) do
      if Keyword.has_key?(opts, :req_format) or Keyword.has_key?(opts, :resp_format) do
        {:error, %Error{reason: :conflicting_formats}}
      else
        resolve_formats(format, format)
      end
    else
      req_format = Keyword.get(opts, :req_format, :json)
      resp_format = Keyword.get(opts, :resp_format, :json)

      resolve_formats(req_format, resp_format)
    end
  end

  defp resolve_formats(req_format, resp_format) do
    with {:ok, req_format} <- validate_format(req_format),
         {:ok, resp_format} <- validate_format(resp_format) do
      {:ok, {req_format, resp_format}}
    end
  end

  defp validate_format(format) when format in @formats, do: {:ok, format}
  defp validate_format(other), do: {:error, %Error{reason: {:invalid_format, other}}}

  defp encode_body(nil, _format, _encoder, _encode), do: {:ok, nil}
  defp encode_body(body, :raw, _encoder, _encode), do: {:ok, body}

  defp encode_body(body, :json, encoder, encode) do
    with {:ok, body} <- cast_body(body, encoder, encode) do
      JSON.encode(body)
    end
  end

  # An ndjson payload is cast per entry, so the encoder goes to `NDJSON` rather
  # than running over the whole list here.
  defp encode_body(body, :ndjson, encoder, encode) do
    guard(fn -> NDJSON.encode(body, encoder: encoder, encode: encode) end)
  end

  defp cast_body(body, encoder, encode) do
    guard(fn -> {:ok, Encoder.run(body, encoder, encode)} end)
  end

  # An encoder is someone else's code: a raise becomes an ordinary error result
  # rather than escaping `new/5`, whose contract is {:ok, request} | {:error, _}.
  defp guard(fun) do
    fun.()
  rescue
    exception -> {:error, %Error{reason: {:encode_failed, exception}}}
  end

  ## Private functions — the response second pass

  defp fetch_key_fn(context, opts) do
    :keys |> resolve_option(context, opts) |> Decoder.key_fun() |> wrap_error()
  end

  defp fetch_decoder(context, opts) do
    with {:ok, decoder} <-
           :decoder |> resolve_option(context, opts) |> Decoder.decoder() |> wrap_error() do
      {:ok, put_context(decoder, context)}
    end
  end

  defp fetch_encoder(context, opts) do
    with {:ok, encoder} <-
           :encoder |> resolve_option(context, opts) |> Encoder.encoder() |> wrap_error() do
      {:ok, put_context(encoder, context)}
    end
  end

  # A decoder/encoder always receives the resolved context alongside its own
  # options, so it is baked in here rather than threaded through every call.
  defp put_context(nil, _context), do: nil
  defp put_context({fun, opts}, context), do: {fun, Keyword.put(opts, :context, context)}

  # Only the call site knows whether the body it built holds a document source,
  # and where — so `:encode` is per request, and off by default.
  defp fetch_encode(opts) do
    opts |> Keyword.get(:encode) |> Encoder.encode() |> wrap_error()
  end

  defp resolve_option(key, context, opts) do
    Keyword.get(opts, key) || Map.fetch!(context, key) ||
      Application.get_env(:dowser_client, key)
  end

  defp wrap_error({:ok, value}), do: {:ok, value}
  defp wrap_error({:error, reason}), do: {:error, %Error{reason: reason}}

  ## Private functions — url

  defp build_url(endpoint, path, params) do
    endpoint |> join(path) |> append_params(params)
  end

  defp join(endpoint, path) do
    cond do
      path in [nil, ""] -> endpoint
      absolute?(path) -> path
      String.starts_with?(path, "/") -> endpoint <> path
      true -> endpoint <> "/" <> path
    end
  end

  defp absolute?(path),
    do: String.starts_with?(path, "http://") or String.starts_with?(path, "https://")

  defp append_params(url, params) when params in [nil, [], %{}], do: url

  defp append_params(url, params) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> encode_query(params)
  end

  defp encode_query(params) do
    params
    |> Enum.map(fn {key, value} -> {to_string(key), query_value(value)} end)
    |> URI.encode_query()
  end

  defp query_value(value) when is_list(value), do: Enum.map_join(value, ",", &to_string/1)
  defp query_value(value), do: to_string(value)

  ## Private functions — headers & http_opts

  # `:headers` is carried inside `:http_opts` at every tier, but the request
  # struct keeps it as its own field (the transport expects a dedicated
  # positional headers argument) — so it's merged separately, and stripped out
  # of the rest of `:http_opts` before that's merged/forwarded.
  defp resolve_http_opts(context, req_format, resp_format, opts) do
    global_opts = Application.get_env(:dowser_client, :http_opts, [])
    context_opts = context.http_opts
    request_opts = Keyword.get(opts, :http_opts, [])

    {global_headers, global_opts} = Keyword.pop(global_opts, :headers, %{})
    {context_headers, context_opts} = Keyword.pop(context_opts, :headers, %{})
    {request_headers, request_opts} = Keyword.pop(request_opts, :headers, %{})

    http_opts =
      global_opts
      |> Keyword.merge(context_opts)
      |> Keyword.merge(request_opts)
      |> merge_ssl([global_opts, context_opts, request_opts])
      |> Keyword.put(:profile, profile(context, request_opts))
      |> Keyword.put(:profile_opts, profile_opts(context, request_opts))

    headers =
      Headers.merge([
        content_type(req_format),
        accept(resp_format),
        global_headers,
        auth_headers(context.auth),
        context_headers,
        request_headers
      ])

    {http_opts, headers}
  end

  # `:ssl` merges per key across the three tiers, so a request overriding one
  # TLS setting doesn't discard the trust store configured on the context.
  defp merge_ssl(http_opts, tiers) do
    case Enum.flat_map(tiers, &Keyword.get(&1, :ssl, [])) do
      [] -> Keyword.delete(http_opts, :ssl)
      ssl_opts -> Keyword.put(http_opts, :ssl, Keyword.new(ssl_opts))
    end
  end

  defp profile(context, request_opts) do
    Keyword.get(request_opts, :profile) || context.profile ||
      Application.get_env(:dowser_client, :profile) || Profile.default()
  end

  defp profile_opts(context, request_opts) do
    Application.get_env(:dowser_client, :profile_opts, [])
    |> Keyword.merge(context.profile_opts)
    |> Keyword.merge(Keyword.get(request_opts, :profile_opts, []))
  end

  defp accept(:json) do
    %{"accept" => @json_mime_type}
  end

  defp accept(:ndjson) do
    %{"accept" => @ndjson_mime_type}
  end

  defp accept(:raw) do
    nil
  end

  defp content_type(:json) do
    %{"content-type" => @json_mime_type}
  end

  defp content_type(:ndjson) do
    %{"content-type" => @ndjson_mime_type}
  end

  defp content_type(:raw) do
    nil
  end

  # A two-element {:basic, _} / {:api_key, _} takes the credential already
  # encoded; the three-element form encodes "username:password" itself.
  defp auth_headers(nil) do
    nil
  end

  defp auth_headers({:basic, value}) do
    authorization("Basic", value)
  end

  defp auth_headers({:basic, username, password}) do
    authorization("Basic", encode_credentials(username, password))
  end

  defp auth_headers({:api_key, value}) do
    authorization("ApiKey", value)
  end

  defp auth_headers({:api_key, id, api_key}) do
    authorization("ApiKey", encode_credentials(id, api_key))
  end

  defp auth_headers({:bearer, token}) do
    authorization("Bearer", token)
  end

  defp auth_headers({:header, name, value}) do
    %{name => value}
  end

  defp authorization(scheme, credentials) do
    %{"authorization" => scheme <> " " <> credentials}
  end

  defp encode_credentials(username, password) do
    Base.encode64("#{username}:#{password}")
  end

  defp validate_auth(auth) do
    if valid_auth?(auth) do
      :ok
    else
      {:error, %Error{reason: {:invalid_auth, auth}}}
    end
  end

  defp valid_auth?(nil), do: true

  defp valid_auth?({scheme, value})
       when scheme in [:basic, :api_key, :bearer] and is_binary(value),
       do: true

  defp valid_auth?({scheme, first, second})
       when scheme in [:basic, :api_key, :header] and is_binary(first) and is_binary(second),
       do: true

  defp valid_auth?(_auth), do: false
end
