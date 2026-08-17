defmodule Dowser.Client.HTTP.Error do
  @moduledoc """
  HTTP transport error.

  Wraps whatever the HTTP adapter surfaced — a bare reason (`:timeout`,
  `:econnrefused`, a `:failed_connect` tuple) or a dependency exception
  (`Mint.TransportError`, ...) — so callers never receive a dependency's own
  exception type. The original term is kept in `:reason` for debugging.
  """

  @type t :: %__MODULE__{
          reason: term(),
          method: atom() | nil,
          url: String.t() | nil,
          adapter: module() | nil,
          attempts: pos_integer()
        }

  defexception [:reason, :method, :url, :adapter, attempts: 1]

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
