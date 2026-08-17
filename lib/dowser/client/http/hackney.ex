defmodule Dowser.Client.HTTP.Hackney do
  @moduledoc """
  HTTP adapter backed by [`:hackney`](https://hex.pm/packages/hackney).

  `:hackney` is an optional dependency. Add `{:hackney, "~> 4.6"}` to your
  deps to use this adapter; a helpful error is raised at call time if it is
  missing.

  `:hackney` only ever speaks HTTP/1.1. Keep-alive comes from connection
  pooling, so a `:pool` is enabled by default (`:default`) — override it with
  your own named pool, but a request without a pool would not reuse
  connections. The `:with_body` option is enabled by default so the full
  response body is returned in one call.

  ## Options

  All `opts` are passed through as `:hackney` request options (e.g. `:pool`,
  `:recv_timeout`, `:connect_timeout`, `:ssl_options`). `:pool` and
  `:with_body` default to `:default` and `true` respectively; `connect_timeout`
  defaults to `2_000` and `recv_timeout` to `30_000` (milliseconds).
  """

  ## Behaviours

  @behaviour Dowser.Client.HTTP.Adapter

  ## Public functions

  if Code.ensure_loaded?(:hackney) do
    alias Dowser.Client.Response

    @default_connect_timeout 2_000

    @default_recv_timeout 30_000

    @impl Dowser.Client.HTTP.Adapter
    def request(method, url, headers, body, opts) do
      hackney_opts =
        opts
        |> Keyword.put_new(:with_body, true)
        |> Keyword.put_new(:pool, :default)
        |> Keyword.put_new(:connect_timeout, @default_connect_timeout)
        |> Keyword.put_new(:recv_timeout, @default_recv_timeout)

      # hackney's header parser only accepts a list of tuples; normalize so a
      # map (which Req and :httpc both tolerate) works here too.
      case :hackney.request(method, url, stringify(headers), body || "", hackney_opts) do
        {:ok, status, resp_headers, resp_body} ->
          {:ok, Response.new(status, resp_headers, to_binary(resp_body))}

        {:ok, status, resp_headers} ->
          {:ok, Response.new(status, resp_headers, "")}

        {:error, reason} ->
          {:error, reason}
      end
    end

    ## Private functions

    defp stringify(headers) do
      Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
    end

    defp to_binary(body) when is_binary(body), do: body
    defp to_binary(body), do: IO.iodata_to_binary(body)
  else
    @impl Dowser.Client.HTTP.Adapter
    def request(_method, _url, _headers, _body, _opts) do
      raise Dowser.Client.Error,
        reason: {:missing_dependency, :hackney},
        message: """
        #{inspect(__MODULE__)} requires the :hackney dependency.

        Add it to your deps:

            {:hackney, "~> 4.6"}
        """
    end
  end
end
