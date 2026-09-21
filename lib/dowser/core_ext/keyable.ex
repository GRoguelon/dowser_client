defprotocol Dowser.CoreExt.Keyable do
  @moduledoc """
  Applies a function to every key of a term, however deeply nested — through
  maps, lists and `MapSet`s; any other term passes through unchanged.

  `Dowser.Client.Decoder` is the pass `dowser_client` runs itself from
  `:keys`/`:decoder`; this protocol casts a whole term's keys in one
  go, for a backend package that needs to do it on its own:

      Dowser.CoreExt.Keyable.transform_keys(body, &String.to_existing_atom/1)

  `String.to_atom/1` grows the atom table for every key a backend ever
  returns, so prefer `String.to_existing_atom/1` on anything attacker- or
  mapping-driven.
  """

  @fallback_to_any true
  @spec transform_keys(term(), (String.t() -> term())) :: term()
  def transform_keys(value, key_fn)
end

defimpl Dowser.CoreExt.Keyable, for: Map do
  def transform_keys(map, key_fn) do
    Map.new(map, fn {key, value} ->
      {transform_key(key, key_fn), @protocol.transform_keys(value, key_fn)}
    end)
  end

  # JSON object keys are always strings; anything else came from elsewhere and
  # is left alone rather than crashing a key function that expects a binary.
  defp transform_key(key, key_fn) when is_binary(key), do: key_fn.(key)
  defp transform_key(key, _key_fn), do: key
end

defimpl Dowser.CoreExt.Keyable, for: List do
  def transform_keys(list, key_fn) do
    Enum.map(list, &@protocol.transform_keys(&1, key_fn))
  end
end

defimpl Dowser.CoreExt.Keyable, for: MapSet do
  def transform_keys(map_set, key_fn) do
    MapSet.new(map_set, &@protocol.transform_keys(&1, key_fn))
  end
end

defimpl Dowser.CoreExt.Keyable, for: Any do
  def transform_keys(value, _key_fn) do
    value
  end
end
