defmodule Dowser.Client.HTTP.Error do
  @moduledoc """
  HTTP transport error.

  Wraps whatever `Dowser.Client.HTTP` surfaced — `:httpc`'s own reason
  (`:timeout`, `:socket_closed_remotely`, a `:failed_connect` tuple, a TLS
  `{:tls_alert, _}`) or one of the transport's (`{:unsupported_body, method}`,
  `{:unknown_http_opts, keys}`, `{:no_cacerts, _}`, `{:profile_down, _}`) — so
  callers handle one exception type. The original term is kept in `:reason`,
  and `:profile` records which `:httpc` profile the request went through.
  """

  @type t :: %__MODULE__{
          reason: term(),
          method: atom() | nil,
          url: String.t() | nil,
          profile: atom() | nil,
          attempts: pos_integer()
        }

  defexception [:reason, :method, :url, :profile, attempts: 1]

  @impl true
  def message(%__MODULE__{reason: reason, method: method, url: url, attempts: attempts}) do
    "HTTP request #{format_method(method)} #{url} failed#{format_attempts(attempts)}: #{format_reason(reason)}"
  end

  defp format_attempts(attempts) when attempts > 1, do: " after #{attempts} attempts"
  defp format_attempts(_attempts), do: ""

  defp format_method(nil), do: "?"

  defp format_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp format_method(method), do: to_string(method)

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
