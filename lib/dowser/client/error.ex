defmodule Dowser.Client.Error do
  @moduledoc """
  Generic Dowser client error.

  Used for failures that are neither HTTP transport nor codec specific —
  e.g. an unknown config or an invalid `:format`/`:keys`/`:retry`. Transport
  failures are `Dowser.Client.HTTP.Error`; JSON failures are
  `Dowser.Client.JSON.Error`; `:codec_adapter` failures are
  `Dowser.Client.Codec.Error`.
  """

  @type t :: %__MODULE__{reason: term(), message: String.t() | nil}

  defexception [:reason, :message]

  @impl true
  def message(%__MODULE__{message: message}) when is_binary(message), do: message

  def message(%__MODULE__{reason: {:unknown_config, name}}) do
    "unknown config #{inspect(name)}"
  end

  def message(%__MODULE__{reason: {:invalid_format, format}}) do
    "invalid format #{inspect(format)}, expected :json, :ndjson or :raw"
  end

  def message(%__MODULE__{reason: :conflicting_formats}) do
    ":format is mutually exclusive with :req_format and :resp_format"
  end

  def message(%__MODULE__{reason: {:invalid_retry, value}}) do
    "invalid :retry option #{inspect(value)}, expected a keyword list or false"
  end

  def message(%__MODULE__{reason: {:invalid_keys, value}}) do
    "invalid :keys option #{inspect(value)}, expected :strings, :atoms or :atoms!"
  end

  def message(%__MODULE__{reason: reason}), do: "Dowser client error: #{inspect(reason)}"
end
