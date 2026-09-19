defmodule Dowser.Client.JSON.Error do
  @moduledoc """
  JSON encoding or decoding error.

  Wraps whatever `Dowser.Client.JSON` surfaced — `JSON`'s own
  `{:unexpected_end, _}`/`{:invalid_byte, _, _}` reason, or a raised
  `Protocol.UndefinedError` for a term that has no JSON representation — so
  callers only handle Dowser exceptions. `:operation` is `:encode` or
  `:decode`; the original term is kept in `:reason`.
  """

  @type t :: %__MODULE__{
          reason: term(),
          operation: :encode | :decode | nil
        }

  defexception [:reason, :operation]

  @impl true
  def message(%__MODULE__{reason: reason, operation: operation}) do
    "JSON #{operation || "codec"} failed: #{format_reason(reason)}"
  end

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
