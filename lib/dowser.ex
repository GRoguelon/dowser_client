defmodule Dowser do
  @moduledoc """
  Top-level convenience helpers shared across the Dowser family.
  """

  @doc """
  Unwraps an `{:ok, value}` / `{:error, exception}` result, as returned by
  `Dowser.Client.request/4`.

  Returns `value` directly, or raises `exception`.
  """
  @spec unwrap({:ok, value} | {:error, Exception.t()}) :: value when value: term()
  def unwrap({:ok, value}), do: value
  def unwrap({:error, error}) when is_exception(error), do: raise(error)

  def unwrap({:error, error}) do
    raise Dowser.Client.Error,
      reason: error,
      message: "unwrap/1 received a non-exception error: #{inspect(error)}"
  end
end
