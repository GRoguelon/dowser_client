defmodule Dowser.Client.HTTP.Httpc do
  @moduledoc """
  HTTP adapter backed by OTP's built-in `:httpc` client.

  Requires no extra dependency — `:inets` and `:ssl` ship with OTP and are
  started lazily on first use.

  The HTTP version is pinned to `HTTP/1.1`. `:httpc` never speaks HTTP/2 and
  keeps connections alive by default (persistent sessions reused per
  host/port), so requests are HTTP/1.1 + keep-alive.

  ## Options

    * `:http_options` — passed as `:httpc`'s `HTTPOptions` (e.g. `timeout`,
      `connect_timeout`, `ssl`). `version: ~c"HTTP/1.1"` is always set.
      `connect_timeout` defaults to `2_000` and `timeout` to `30_000`
      (milliseconds); either can be overridden by the caller.
    * `:options` — passed as `:httpc`'s `Options`. `body_format: :binary` is
      always set so the response body comes back as a binary.

  ## Body support is method-dependent

  `:httpc` only accepts a request body for `:post`, `:put`, `:patch`,
  `:delete` and `:options` — its request tuple for every other method
  (`:get`, `:head`, ...) has no slot for one. A body given for one of those
  methods returns `{:error, {:unsupported_body, method}}` rather than being
  silently dropped. This is a real backend-compatibility gap: search APIs
  that expect a body on `GET` (e.g. Elasticsearch's `GET /_search`) need
  `Dowser.Client.HTTP.Req` or `Dowser.Client.HTTP.Hackney` instead.
  """

  alias Dowser.Client.Response

  ## Behaviours

  @behaviour Dowser.Client.HTTP.Adapter

  ## Module attributes

  @body_methods [:post, :put, :patch, :delete, :options]

  @default_content_type "application/json"

  @default_connect_timeout 2_000

  @default_timeout 30_000

  ## Public functions

  @impl Dowser.Client.HTTP.Adapter
  def request(method, url, headers, body, opts) do
    with {:ok, request} <- build_request(method, url, headers, body) do
      http_options =
        opts
        |> Keyword.get(:http_options, [])
        |> Keyword.put_new(:connect_timeout, @default_connect_timeout)
        |> Keyword.put_new(:timeout, @default_timeout)
        |> Keyword.put(:version, ~c"HTTP/1.1")

      options = opts |> Keyword.get(:options, []) |> Keyword.put(:body_format, :binary)

      case :httpc.request(method, request, http_options, options) do
        {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
          {:ok, Response.new(status, resp_headers, to_binary(resp_body))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  ## Private functions

  # :httpc requires the body-carrying request tuple for these methods, so a
  # nil body is sent as an empty one.
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

  defp pop_content_type(headers) do
    case Enum.split_with(headers, fn {k, _} -> String.downcase(k) == "content-type" end) do
      {[{_, value} | _], rest} -> {value, rest}
      {[], rest} -> {@default_content_type, rest}
    end
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: IO.iodata_to_binary(body)
end
