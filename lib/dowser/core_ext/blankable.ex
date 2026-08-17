defprotocol Dowser.Blankable do
  @moduledoc false

  @fallback_to_any true
  def blank?(value)
end

defimpl Dowser.Blankable, for: Atom do
  def blank?(value) do
    is_nil(value)
  end
end

defimpl Dowser.Blankable, for: [String, BitString] do
  def blank?(value) do
    String.trim(value) == ""
  end
end

defimpl Dowser.Blankable, for: MapSet do
  def blank?(value) do
    value == MapSet.new()
  end
end

defimpl Dowser.Blankable, for: Map do
  def blank?(value) do
    value == %{}
  end
end

defimpl Dowser.Blankable, for: List do
  def blank?(value) do
    value == []
  end
end

defimpl Dowser.Blankable, for: Any do
  def blank?(_value) do
    false
  end
end
