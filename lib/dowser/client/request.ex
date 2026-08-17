defmodule Dowser.Client.Request do
  @moduledoc """
  A fully-resolved HTTP request, ready to hand to an HTTP adapter.

  `new/5` turns a `Dowser.Client.Config` plus a method, path, body and
  per-request options into a `%Request{}`. All option resolution happens here,
  so an adapter only ever sees a finished request:

    * **headers** — merge of global (`config :dowser_client, :http_opts,
      headers: ...`), config (`auth` + config `http_opts[:headers]`) and
      per-request (`opts[:http_opts][:headers]`) headers, plus a
      `content-type` derived from the request format. Later sources win on
      name clashes. Each source accepts either a map or a list of
      `{name, value}` pairs.
    * **url** — the config's endpoint joined with the request path and, when
      given, `opts[:params]` encoded as a query string. An absolute path is
      used verbatim.
    * **body** — cast through `:codec_adapter` (see Casting below), then
      encoded according to the request format (`:json`, `:ndjson` or `:raw`)
      using the resolved JSON adapter and `:json_opts`.
    * **adapter / http_opts** — the resolved `:http_adapter` and `:http_opts`
      (minus `:headers`, forwarded separately — see above), merged
      global → config → request.
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

  Response/request bodies are cast in two independent ways:

    * `:keys` — `:strings` (default), `:atoms` or `:atoms!`; how a decoded
      response body's keys are cast. Falls back to the config's `:keys`, then
      `config :dowser_client, :keys`, then `:strings`. Resolved into a
      `:key_fn` function and passed to `:codec_adapter` via `:codec_opts` —
      the default `Dowser.Client.Codec.Default` applies it; a custom
      `:codec_adapter` is responsible for applying it itself if it wants the
      same behavior.
    * `:codec_adapter` — a module implementing `Dowser.Client.Codec`, falling
      back to the config's `:codec_adapter`, then
      `config :dowser_client, :codec_adapter`, then
      `Dowser.Client.Codec.Default` (`dowser_client` has no
      backend-specific knowledge of its own beyond that). When set,
      `codec_adapter.decode/2` casts the response body in one pass, and
      `codec_adapter.encode/2` casts the request body before JSON encoding.
      `:codec_opts` (merged global → config → request) is forwarded to both,
      alongside `:key_fn` and `:config` (the resolved `Dowser.Client.Config`).

  All casting is skipped when the format is `:raw` or the body is empty.
  """

  alias Dowser.Client.Codec.Error, as: CodecError
  alias Dowser.Client.Codec.Default, as: DefaultCodec
  alias Dowser.Client.Error
  alias Dowser.Client.Headers
  alias Dowser.Client.JSON.Error, as: JSONError
  alias Dowser.Client.NDJSON
  alias Dowser.Client.Retry

  ## Structure

  defstruct [
    :http_adapter,
    :json_adapter,
    :codec_adapter,
    :http_opts,
    :json_opts,
    :codec_opts,
    :resp_format,
    :url,
    :method,
    :headers,
    :body,
    :retry
  ]

  ## Typespecs

  @type format :: :json | :ndjson | :raw
  @type keys :: :strings | :atoms | :atoms!

  ## Module attributes

  @formats [:json, :ndjson, :raw]
  @keys [:strings, :atoms, :atoms!]

  @json_mime_type "application/json"
  @ndjson_mime_type "application/x-ndjson"

  ## Public functions

  def new(config, method, path, body, opts) do
    request = %__MODULE__{
      http_adapter: http_adapter(config, opts),
      json_adapter: json_adapter(config, opts),
      codec_adapter: codec_adapter(config, opts),
      json_opts: resolve_opts(config, :json_opts, opts),
      codec_opts: resolve_opts(config, :codec_opts, opts)
    }

    with {:ok, {req_format, resp_format}} <- fetch_formats(opts),
         {:ok, keys} <- fetch_keys(config, opts),
         {:ok, retry} <- Retry.resolve(opts),
         {:ok, encoded_body} <-
           encode_body(request, body, req_format) do
      {http_opts, headers} = resolve_http_opts(config, req_format, resp_format, opts)
      query_params = Keyword.get(opts, :params)
      key_fn = key_fn(keys)

      request =
        %{
          request
          | url: build_url(config.endpoint, path, query_params),
            method: method,
            headers: headers,
            body: encoded_body,
            retry: retry,
            http_opts: http_opts,
            resp_format: resp_format,
            codec_opts: Keyword.put(request.codec_opts, :key_fn, key_fn)
        }

      {:ok, request}
    end
  end

  def run(%__MODULE__{http_adapter: http_adapter} = request) do
    http_adapter.request(
      request.method,
      request.url,
      request.headers,
      request.body,
      request.http_opts
    )
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

  defp fetch_keys(config, opts) do
    keys_value =
      Keyword.get(opts, :keys) || config.keys || Application.get_env(:dowser_client, :keys) ||
        :strings

    if keys_value in @keys do
      {:ok, keys_value}
    else
      {:error, %Error{reason: {:invalid_keys, keys_value}}}
    end
  end

  defp encode_body(_request, nil, _format) do
    {:ok, nil}
  end

  defp encode_body(_request, body, :raw) do
    {:ok, body}
  end

  defp encode_body(request, body, format) do
    with {:ok, body} <- cast_body(request, body) do
      do_encode_body(request, body, format)
    end
  end

  defp cast_body(%{codec_adapter: DefaultCodec}, body) do
    {:ok, body}
  end

  defp cast_body(%{codec_adapter: codec_adapter, codec_opts: codec_opts}, body) do
    codec_adapter.encode(body, codec_opts)
  rescue
    exception ->
      {:error, %CodecError{reason: exception, codec: codec_adapter, operation: :encode}}
  end

  defp do_encode_body(%{json_adapter: json_adapter, json_opts: json_opts}, body, :json) do
    encode_fn = &json_adapter.encode(&1, json_opts)
    error_fn = &%JSONError{reason: &1, operation: :encode, adapter: json_adapter}

    do_encode_body2(body, encode_fn, error_fn)
  end

  defp do_encode_body(%{json_adapter: json_adapter, json_opts: json_opts}, body, :ndjson) do
    encode_fn = &NDJSON.encode(&1, json_adapter, json_opts)
    error_fn = &%JSONError{reason: &1, operation: :encode, adapter: {NDJSON, json_adapter}}

    do_encode_body2(body, encode_fn, error_fn)
  end

  defp do_encode_body2(body, encode_fn, error_fn) do
    case encode_fn.(body) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, error_fn.(reason)}
    end
  rescue
    exception ->
      {:error, error_fn.(exception)}
  end

  ## Private functions — adapters & opts merging

  defp http_adapter(config, opts) do
    Keyword.get(opts, :http_adapter) || config.http_adapter ||
      Application.get_env(:dowser_client, :http_adapter, Dowser.Client.HTTP.Httpc)
  end

  defp json_adapter(config, opts) do
    Keyword.get(opts, :json_adapter) || config.json_adapter ||
      Application.get_env(:dowser_client, :json_adapter, Dowser.Client.JSON.Native)
  end

  defp codec_adapter(config, opts) do
    if Keyword.has_key?(opts, :codec_adapter) do
      Keyword.fetch!(opts, :codec_adapter) || DefaultCodec
    else
      config.codec_adapter || Application.get_env(:dowser_client, :codec_adapter, DefaultCodec)
    end
  end

  defp resolve_opts(config, key, opts) do
    global_opts = Application.get_env(:dowser_client, key, [])
    config_opts = Map.fetch!(config, key)
    request_opts = Keyword.get(opts, key, [])

    global_opts
    |> Keyword.merge(config_opts)
    |> Keyword.merge(request_opts)
    |> then(fn opts ->
      if key == :codec_opts do
        Keyword.put(opts, :config, config)
      else
        opts
      end
    end)
  end

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
  # struct keeps it as its own field (adapters expect a dedicated positional
  # headers argument) — so it's merged separately, and stripped out of the
  # rest of `:http_opts` before that's merged/forwarded to the adapter.
  defp resolve_http_opts(config, req_format, resp_format, opts) do
    global_opts = Application.get_env(:dowser_client, :http_opts, [])
    config_opts = config.http_opts
    request_opts = Keyword.get(opts, :http_opts, [])

    {global_headers, global_opts} = Keyword.pop(global_opts, :headers, %{})
    {config_headers, config_opts} = Keyword.pop(config_opts, :headers, %{})
    {request_headers, request_opts} = Keyword.pop(request_opts, :headers, %{})

    http_opts =
      global_opts
      |> Keyword.merge(config_opts)
      |> Keyword.merge(request_opts)

    headers =
      Headers.merge([
        content_type(req_format),
        accept(resp_format),
        global_headers,
        auth_headers(config.auth),
        config_headers,
        request_headers
      ])

    {http_opts, headers}
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

  defp auth_headers(nil) do
    nil
  end

  defp auth_headers({:basic, username, password}) do
    %{"authorization" => "Basic " <> Base.encode64("#{username}:#{password}")}
  end

  defp auth_headers({:bearer, token}) do
    %{"authorization" => "Bearer " <> token}
  end

  defp auth_headers({:api_key, key}) do
    %{"authorization" => "ApiKey " <> key}
  end

  defp auth_headers({:header, name, value}) do
    %{name => value}
  end

  def key_fn(:strings), do: &Function.identity/1
  def key_fn(:atoms), do: &String.to_atom/1
  def key_fn(:atoms!), do: &String.to_existing_atom/1
end
