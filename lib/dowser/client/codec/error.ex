defmodule Dowser.Client.Codec.Error do
  @moduledoc """
  Codec error.

  Wraps an exception raised by a `:codec_adapter`'s `decode/2` or `encode/2` so
  callers never receive a dependency's own exception type. The original
  exception is kept in `:reason`, and which direction failed in `:operation`.
  """

  @type t :: %__MODULE__{
          reason: term(),
          codec: module() | nil,
          operation: :decode | :encode | nil
        }

  defexception [:reason, :codec, :operation]

  @impl true
  def message(%__MODULE__{reason: reason, codec: codec, operation: operation}) do
    "#{format_operation(operation)} failed#{format_codec(codec)}: #{format_reason(reason)}"
  end

  defp format_operation(nil), do: "codec"
  defp format_operation(operation), do: "codec #{operation}"

  defp format_codec(nil), do: ""
  defp format_codec(codec), do: " (#{inspect(codec)})"

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
