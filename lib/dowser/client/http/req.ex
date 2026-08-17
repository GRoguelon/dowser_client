defmodule Dowser.Client.HTTP.Req do
  @moduledoc """
  HTTP adapter backed by the [`Req`](https://hex.pm/packages/req) library.

  `Req` is an optional dependency. Add `{:req, "~> 0.5"}` to your deps to use
  this adapter; a helpful error is raised at call time if it is missing.

  Response body decoding is disabled (`decode_body: false`) so Dowser receives
  the raw payload and handles JSON/NDJSON itself.

  The transport is pinned to HTTP/1.1 via `connect_options: [protocols:
  [:http1]]` (otherwise Mint would negotiate HTTP/2 over ALPN on TLS). Finch
  pools the connection, giving keep-alive. This is enforced after merging
  caller `opts`, so `:protocols` cannot be accidentally overridden.

  `receive_timeout` defaults to `30_000` and `connect_options[:timeout]` to
  `2_000` (milliseconds); either can be overridden by the caller. Finch's own
  `:pool_timeout` (time spent waiting to check out a pooled connection)
  already defaults to `5_000`, so it is left untouched here — setting it
  explicitly would require the `:finch` option, which Req refuses to combine
  with the `:connect_options` this adapter relies on for the HTTP/1.1 pin.

  Req's own built-in retry (`retry: :safe_transient` by default) is disabled
  by default, since retry is handled once, generically, by
  `Dowser.Client.Retry` regardless of adapter — leaving Req's retry on too
  would silently multiply the number of attempts. Pass `retry: :safe_transient`
  (or any other `Req` retry option) through `opts` to opt back into it.

  ## Options

  All `opts` are merged into the `Req.request/1` options and win over the
  defaults set here, so any `Req` option (e.g. `retry`, `receive_timeout`)
  can be passed through. Extra `:connect_options` are honored and merged with
  the enforced `:protocols`.
  """

  ## Behaviours

  @behaviour Dowser.Client.HTTP.Adapter

  ## Public functions

  if Code.ensure_loaded?(Req) do
    alias Dowser.Client.Response

    @default_connect_timeout 2_000

    @default_receive_timeout 30_000

    @impl Dowser.Client.HTTP.Adapter
    def request(method, url, headers, body, opts) do
      connect_options =
        opts
        |> Keyword.get(:connect_options, [])
        |> Keyword.put_new(:timeout, @default_connect_timeout)
        |> Keyword.put(:protocols, [:http1])

      options =
        [
          method: method,
          url: url,
          headers: headers,
          decode_body: false,
          retry: false,
          receive_timeout: @default_receive_timeout
        ]
        |> maybe_put_body(body)
        |> Keyword.merge(opts)
        |> Keyword.put(:connect_options, connect_options)

      case Req.request(options) do
        {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
          {:ok, Response.new(status, normalize_headers(resp_headers), to_binary(resp_body))}

        {:error, reason} ->
          {:error, reason}
      end
    end

    ## Private functions

    defp maybe_put_body(options, nil), do: options
    defp maybe_put_body(options, body), do: Keyword.put(options, :body, body)

    # Req >= 0.4 returns headers as a map of name => list-of-values.
    defp normalize_headers(headers) when is_map(headers) do
      for {k, values} <- headers, v <- List.wrap(values), do: {to_string(k), to_string(v)}
    end

    defp normalize_headers(headers) when is_list(headers) do
      Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
    end

    defp to_binary(body) when is_binary(body), do: body
    defp to_binary(body) when is_list(body), do: IO.iodata_to_binary(body)
    defp to_binary(body), do: to_string(body)
  else
    @impl Dowser.Client.HTTP.Adapter
    def request(_method, _url, _headers, _body, _opts) do
      raise Dowser.Client.Error,
        reason: {:missing_dependency, :req},
        message: """
        #{inspect(__MODULE__)} requires the :req dependency.

        Add it to your deps:

            {:req, "~> 0.7"}
        """
    end
  end
end
