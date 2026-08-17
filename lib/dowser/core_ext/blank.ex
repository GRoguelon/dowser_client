defmodule Dowser.Blank do
  @moduledoc false

  alias Dowser.Blankable

  ## Public functions

  def blank?(value) do
    Blankable.blank?(value)
  end

  def present?(value) do
    not Blankable.blank?(value)
  end

  def presence(value) do
    if not Blankable.blank?(value) do
      value
    end
  end
end
