defprotocol Dowser.CoreExt.Keyable do
  @moduledoc false

  @fallback_to_any true
  def transform_keys(value, key_fn)
end

defimpl Dowser.CoreExt.Keyable, for: Map do
  def transform_keys(map, key_fn) do
    Map.new(map, fn {key, value} ->
      {key_fn.(key), @protocol.transform_keys(value, key_fn)}
    end)
  end
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
