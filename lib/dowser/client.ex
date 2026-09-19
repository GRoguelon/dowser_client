defmodule Dowser.Client do
  @moduledoc """
  Low-level entry point for querying a search backend over HTTP.

  `request/4` resolves every option into a `Dowser.Client.Request`, performs it
  over `Dowser.Client.HTTP` (OTP's `:httpc`), and decodes the response body
  according to `:format`, returning `{:ok, %Dowser.Client.Response{}}` or
  `{:error, exception}`.

  All option resolution — header merging, URL/query building and body encoding —
  happens in `Dowser.Client.Request.new/5` before the transport is called;
  response decoding follows the same `:format`.

  ## Errors

  Errors are always Dowser exceptions, never a dependency's own exception type:

    * `Dowser.Client.Error` — context resolution, invalid
      `:auth`/`:format`/`:keys`/`:decoder`/`:encoder`/`:encode`/`:retry`, or a
      `:keys`, `:decoder` or `:encoder` function that raised.
    * `Dowser.Client.JSON.Error` — body encoding or decoding failure.
    * `Dowser.Client.HTTP.Error` — transport failure.

  ## Options

  Every option below can be set globally (`config :dowser_client, ...`), per
  context (`Dowser.Client.Context`), or per request — most specific wins, except
  `:http_opts`, which merges across all three (most specific wins per key).

    * `:context` — the search backend to query (see `Dowser.Client.Context`);
      absent resolves the `:default` entry from `config :dowser_client,
      contexts: [...]` (there is no other built-in fallback).
    * `:params` — query-string parameters appended to the URL.
    * `:format` — `:json` (default), `:ndjson` or `:raw`; selects the codec used
      to encode the request body *and* decode the response body (`:raw` leaves
      both untouched). Mutually exclusive with `:req_format`/`:resp_format`.
    * `:req_format` / `:resp_format` — set the request and response formats
      independently; each falls back to `:format` (so `:json`) when omitted.
    * `:keys` — `:strings` (default), `:atoms`, `:atoms!`, or a
      `(String.t() -> term)` function; how a decoded response body's keys are
      cast.
    * `:decoder` — a module exporting `decode/2`, a `(body, opts -> term)`
      function, or either paired with the options it needs
      (`{MyDecoder, mapping: mapping}`), owning the decoded response body. It
      receives its own options plus `:key_fn` and `:context`, and does the
      backend-specific casting `dowser_client` can't: finding documents in the
      envelope, resolving each one's mapping, casting its fields.
    * `:encoder` — a module exporting `encode/2`, a `(source, opts -> term)`
      function, or either paired with the options it needs
      (`{MyEncoder, index: "articles"}`), casting a **document source** in a
      request body against the mapping of the index it is going to. A query is
      never encoded.
    * `:encode` — where that source is in this request's body: `false` (default),
      `true` (the body is the source), a path (`["doc"]` for an update), or a
      list of paths. Per request only — the call site is the only place that
      knows. See `Dowser.Client.Encoder`.
    * `:keys` and `:decoder` drive one optional second pass over the decoded
      body; with neither set there is no second pass and the body stays the
      plain, string-keyed term `Dowser.Client.JSON`/`Dowser.Client.NDJSON`
      produced. See `Dowser.Client.Decoder`.
    * `:http_opts` — transport options forwarded to
      `Dowser.Client.HTTP.request/5` — `:connect_timeout`, `:timeout`, `:ssl`,
      `:profile`, `:profile_opts`, ... — including `:headers` (a map or list of
      `{name, value}` pairs, merged over global and context headers plus a
      derived `content-type`). `:ssl` and `:profile_opts` merge per key across
      the three tiers; see `Dowser.Client.HTTP`.
    * `:retry` — retry policy for transient failures; see `Dowser.Client.Retry`.
  """

  alias Dowser.Client.Context
  alias Dowser.Client.Error
  alias Dowser.Client.HTTP.Error, as: HTTPError
  alias Dowser.Client.Request
  alias Dowser.Client.Response
  alias Dowser.Client.Retry

  ## Typespecs

  @type method :: Dowser.Client.HTTP.method()
  @type result :: {:ok, Response.t()} | {:error, Exception.t()}

  ## Public functions

  @doc """
  Runs an HTTP request against the context given in `opts[:context]`.

  Returns `{:ok, %Dowser.Client.Response{}}` on a completed exchange (any HTTP
  status), or `{:error, exception}` when the context cannot be resolved, the
  body cannot be encoded/decoded, or the transport fails.
  """
  @spec request(method(), String.t(), term(), keyword()) :: result()
  def request(method, path, body \\ nil, opts \\ []) do
    {context_ref, opts} = Keyword.pop(opts, :context)

    with {:ok, context} <- resolve_context(context_ref),
         {:ok, request} <- Request.new(context, method, path, body, opts) do
      perform(request)
    end
  end

  @doc "Runs a `GET`; see `request/4`."
  @spec get(String.t(), keyword()) :: result()
  def get(path, opts \\ []) do
    request(:get, path, nil, opts)
  end

  @doc "Runs a `POST`; see `request/4`."
  @spec post(String.t(), term(), keyword()) :: result()
  def post(path, body \\ nil, opts \\ []) do
    request(:post, path, body, opts)
  end

  @doc "Runs a `PUT`; see `request/4`."
  @spec put(String.t(), term(), keyword()) :: result()
  def put(path, body \\ nil, opts \\ []) do
    request(:put, path, body, opts)
  end

  @doc "Runs a `PATCH`; see `request/4`."
  @spec patch(String.t(), term(), keyword()) :: result()
  def patch(path, body \\ nil, opts \\ []) do
    request(:patch, path, body, opts)
  end

  @doc "Runs a `DELETE`; see `request/4`."
  @spec delete(String.t(), term(), keyword()) :: result()
  def delete(path, body \\ nil, opts \\ []) do
    request(:delete, path, body, opts)
  end

  ## Private functions

  defp resolve_context(context_ref) do
    case Context.resolve(context_ref) do
      {:ok, context} ->
        {:ok, context}

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
      profile: Keyword.get(request.http_opts, :profile),
      attempts: attempts
    }
  end
end
