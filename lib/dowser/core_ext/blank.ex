defmodule Dowser.Blank do
  @moduledoc false

  alias Dowser.Blankable

  ## Public functions

  @doc "Whether `value` is blank, per `Dowser.Blankable`."
  @spec blank?(term()) :: boolean()
  defdelegate blank?(value), to: Blankable

  @doc "The negation of `blank?/1`."
  @spec present?(term()) :: boolean()
  def present?(value) do
    not Blankable.blank?(value)
  end

  def presence(value) do
    if not Blankable.blank?(value) do
      value
    end
  end
end
