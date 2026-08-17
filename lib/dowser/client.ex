defmodule Dowser.Client do
  @moduledoc """
  Low-level entry point for querying a search backend over HTTP.

  `request/4` resolves every option into a `Dowser.Client.Request`, performs it
  against the resolved config's HTTP adapter, and decodes the response body
  according to `:format`, returning `{:ok, %Dowser.Client.Response{}}` or
  `{:error, exception}`.

  All option resolution — header merging, URL/query building, adapter selection
  and body encoding — happens in `Dowser.Client.Request.new/5` before the
  adapter is called; response decoding uses the same `:format`/JSON adapter.

  ## Errors

  Errors are always Dowser exceptions, never a dependency's own exception type:

    * `Dowser.Client.Error` — config resolution / invalid `:format`/`:keys`/`:retry`.
    * `Dowser.Client.JSON.Error` — body encoding or decoding failure.
    * `Dowser.Client.Codec.Error` — `:codec_adapter` `decode/2`/`encode/2` failure.
    * `Dowser.Client.HTTP.Error` — transport failure.

  ## Options

  Every option below can be set globally (`config :dowser_client, ...`), per
  config (`Dowser.Client.Config`), or per request — most specific wins, except
  the three `_opts` keyword lists (`:codec_opts`, `:json_opts`, `:http_opts`),
  which merge across all three (most specific wins per key).

    * `:config` — the config to query (see `Dowser.Client.Config`); absent
      resolves the `:default` entry from `config :dowser_client, configs:
      [...]` (there is no other built-in fallback).
    * `:params` — query-string parameters appended to the URL.
    * `:format` — `:json` (default), `:ndjson` or `:raw`; selects the codec used
      to encode the request body *and* decode the response body (`:raw` leaves
      both untouched). Mutually exclusive with `:req_format`/`:resp_format`.
    * `:req_format` / `:resp_format` — set the request and response formats
      independently; each falls back to `:format` (so `:json`) when omitted.
    * `:codec_adapter` — a module implementing `Dowser.Client.Codec`, used to
      cast a decoded response body via `decode/2`, and a request body via
      `encode/2`, beyond plain JSON. Defaults to
      `Dowser.Client.Codecs.DefaultCodec`, which only applies `:keys` casting
      below; see `Dowser.Client.Codec` for the full contract.
    * `:codec_opts` — options forwarded to `:codec_adapter`'s `decode/2`/
      `encode/2` (e.g. an index mapping); default `[]`.
    * `:keys` — `:strings` (default), `:atoms` or `:atoms!`; how object keys in
      the response body are cast. Applied by the default `:codec_adapter`; a
      custom one is responsible for applying `opts[:key_fn]` itself if it
      wants the same behavior.
    * `:http_adapter` / `:json_adapter` — the HTTP/JSON adapter modules.
    * `:json_opts` — options forwarded to the JSON adapter's `encode/2`/`decode/2`.
    * `:http_opts` — options forwarded to the HTTP adapter's `request/5`,
      including `:headers` (a map or list of `{name, value}` pairs, merged
      over global and config headers plus a derived `content-type`).
    * `:retry` — retry policy for transient failures; see `Dowser.Client.Retry`.
  """

  alias Dowser.Client.Config
  alias Dowser.Client.Error
  alias Dowser.Client.HTTP.Error, as: HTTPError
  alias Dowser.Client.Request
  alias Dowser.Client.Response
  alias Dowser.Client.Retry

  ## Typespecs

  @type method :: Dowser.Client.HTTP.Adapter.method()
  @type result :: {:ok, Response.t()} | {:error, Exception.t()}

  ## Public functions

  @doc """
  Runs an HTTP request against the config given in `opts[:config]`.

  Returns `{:ok, %Dowser.Client.Response{}}` on a completed exchange (any HTTP
  status), or `{:error, exception}` when the config cannot be resolved, the body
  cannot be encoded/decoded, or the transport fails.
  """
  @spec request(method(), String.t(), term(), keyword()) :: result()
  def request(method, path, body \\ nil, opts \\ []) do
    {config_ref, opts} = Keyword.pop(opts, :config)

    with {:ok, config} <- resolve_config(config_ref),
         {:ok, request} <- Request.new(config, method, path, body, opts) do
      perform(request)
    end
  end

  def get(path, opts \\ []) do
    request(:get, path, nil, opts)
  end

  def post(path, body \\ nil, opts \\ []) do
    request(:post, path, body, opts)
  end

  def put(path, body \\ nil, opts \\ []) do
    request(:put, path, body, opts)
  end

  def patch(path, body \\ nil, opts \\ []) do
    request(:patch, path, body, opts)
  end

  def delete(path, body \\ nil, opts \\ []) do
    request(:delete, path, body, opts)
  end

  ## Private functions

  defp resolve_config(config_ref) do
    case Config.resolve(config_ref) do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        {:error, %Error{reason: reason}}
    end
  end

  defp perform(%Request{} = request) do
    {result, attempts} =
      Retry.run(request.retry, fn ->
        Request.run(request)
      end)

    finalize(result, request, attempts)
  rescue
    exception -> {:error, exception}
  end

  defp finalize({:ok, %Response{} = response}, request, _attempts) do
    Response.decode(response, request)
  end

  defp finalize({:error, reason}, request, attempts) do
    {:error, http_error(reason, request, attempts)}
  end

  defp http_error(reason, %Request{} = request, attempts) do
    %HTTPError{
      reason: reason,
      method: request.method,
      url: request.url,
      adapter: request.http_adapter,
      attempts: attempts
    }
  end
end
