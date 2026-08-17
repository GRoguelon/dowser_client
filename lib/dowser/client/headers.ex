defmodule Dowser.Client.Headers do
  @moduledoc false

  @doc "Normalizes a map or list of `{name, value}` pairs into a list of string tuples."
  def normalize(nil), do: []

  def normalize(headers) when is_map(headers) or is_list(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  @doc """
  Merges header sources in order, keeping the last value for each
  (case-insensitive) name while preserving overall order.
  """
  def merge(sources) do
    sources
    |> Enum.flat_map(&normalize/1)
    |> Enum.reverse()
    |> Enum.uniq_by(fn {name, _value} -> String.downcase(name) end)
    |> Enum.reverse()
  end
end
