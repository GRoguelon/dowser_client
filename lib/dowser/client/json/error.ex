defmodule Dowser.Client.JSON.Error do
  @moduledoc """
  JSON codec error.

  Wraps whatever a `Dowser.Client.JSON.Adapter` surfaced while encoding or
  decoding — a returned `{:error, reason}` or a raised dependency exception
  (`Jason.EncodeError`, `Protocol.UndefinedError`, ...) — so callers never
  receive a dependency's own exception type. `:operation` is `:encode` or
  `:decode`; the original term is kept in `:reason`.
  """

  @type t :: %__MODULE__{
          reason: term(),
          operation: :encode | :decode | nil,
          adapter: module() | nil
        }

  defexception [:reason, :operation, :adapter]

  @impl true
  def message(%__MODULE__{reason: reason, operation: operation}) do
    "JSON #{operation || "codec"} failed: #{format_reason(reason)}"
  end

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
