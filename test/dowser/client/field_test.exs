defmodule Dowser.Client.FieldTest do
  use ExUnit.Case, async: true

  test "declares load/2 and dump/2 as behaviour callbacks" do
    assert Dowser.Client.Field.behaviour_info(:callbacks) |> Enum.sort() == [dump: 2, load: 2]
  end
end
