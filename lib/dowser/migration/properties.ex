defmodule Dowser.Migration.Properties do
  @moduledoc false

  # A mapping as the migrator changes it — string keys, the shape the engine
  # returns — addressed by field path through `properties`.

  @type mapping :: map()
  @type path :: [String.t()]

  @doc "The definition of the field at `path`."
  @spec fetch(mapping(), path()) :: {:ok, map()} | :error
  def fetch(mapping, [name]) do
    mapping |> Map.get("properties", %{}) |> Map.fetch(name)
  end

  def fetch(mapping, [name | rest]) do
    case fetch(mapping, [name]) do
      {:ok, field} ->
        fetch(field, rest)

      :error ->
        :error
    end
  end

  @doc """
  Whether a field can be added under `parent`: the mapping's root, or an
  `object` or `nested` field.
  """
  @spec object?(mapping(), path()) :: boolean()
  def object?(_mapping, []), do: true

  def object?(mapping, parent) do
    case fetch(mapping, parent) do
      {:ok, field} ->
        Map.has_key?(field, "properties") or Map.get(field, "type") in ["object", "nested"]

      :error ->
        false
    end
  end

  @doc "Sets the definition of the field at `path`; its parent exists."
  @spec put(mapping(), path(), map()) :: mapping()
  def put(mapping, [name], definition) do
    Map.update(mapping, "properties", %{name => definition}, &Map.put(&1, name, definition))
  end

  def put(mapping, [name | rest], definition) do
    update_in(mapping, ["properties", name], &put(&1, rest, definition))
  end

  @doc "Removes the field at `path`; it exists."
  @spec delete(mapping(), path()) :: mapping()
  def delete(mapping, [name]), do: update_in(mapping, ["properties"], &Map.delete(&1, name))

  def delete(mapping, [name | rest]) do
    update_in(mapping, ["properties", name], &delete(&1, rest))
  end

  @doc """
  The part of `mapping` holding the fields at `paths`: a body adding them with
  a put-mapping request. Each parent keeps its `type`, so a `nested` parent
  stays nested.
  """
  @spec subset(mapping(), [path()]) :: mapping()
  def subset(mapping, paths) do
    Enum.reduce(paths, %{}, fn path, acc -> merge(acc, branch(mapping, path)) end)
  end

  defp branch(mapping, [name]) do
    %{"properties" => %{name => get_in(mapping, ["properties", name])}}
  end

  defp branch(mapping, [name | rest]) do
    parent = get_in(mapping, ["properties", name])

    %{"properties" => %{name => parent |> Map.take(["type"]) |> merge(branch(parent, rest))}}
  end

  defp merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r ->
        merge(l, r)

      _key, _l, r ->
        r
    end)
  end

  @doc """
  Whether two field definitions are the same, as the engine stores them:
  scalars compared as strings (`256` and `"256"`, `:keyword` and
  `"keyword"`).
  """
  @spec same?(term(), term()) :: boolean()
  def same?(left, right), do: normalize(left) == normalize(right)

  defp normalize(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(nil), do: nil
  defp normalize(value) when is_float(value), do: Float.to_string(value)
  defp normalize(value), do: to_string(value)
end
