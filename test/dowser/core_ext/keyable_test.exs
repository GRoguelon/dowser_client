defmodule Dowser.CoreExt.KeyableTest do
  use ExUnit.Case, async: true

  alias Dowser.CoreExt.Keyable

  describe "Map" do
    test "transforms every key with key_fn" do
      assert Keyable.transform_keys(%{"a" => 1, "b" => 2}, &String.to_atom/1) == %{a: 1, b: 2}
    end

    test "recurses into nested map values" do
      assert Keyable.transform_keys(%{"a" => %{"b" => 1}}, &String.to_atom/1) == %{a: %{b: 1}}
    end

    test "an empty map stays empty" do
      assert Keyable.transform_keys(%{}, &String.to_atom/1) == %{}
    end

    test "leaves already-transformed keys and non-collection values untouched" do
      assert Keyable.transform_keys(%{"a" => "x", "b" => 1, "c" => true}, &String.to_atom/1) ==
               %{a: "x", b: 1, c: true}
    end
  end

  describe "List" do
    test "recurses into every element" do
      assert Keyable.transform_keys([%{"a" => 1}, %{"b" => 2}], &String.to_atom/1) ==
               [%{a: 1}, %{b: 2}]
    end

    test "preserves order" do
      assert Keyable.transform_keys([%{"a" => 1}, %{"a" => 2}, %{"a" => 3}], &String.to_atom/1) ==
               [%{a: 1}, %{a: 2}, %{a: 3}]
    end

    test "an empty list stays empty" do
      assert Keyable.transform_keys([], &String.to_atom/1) == []
    end

    test "a list of scalars passes through unchanged" do
      assert Keyable.transform_keys([1, "a", true, nil], &String.to_atom/1) == [1, "a", true, nil]
    end

    test "a list nested inside a map is recursed into" do
      assert Keyable.transform_keys(%{"items" => [%{"a" => 1}]}, &String.to_atom/1) ==
               %{items: [%{a: 1}]}
    end
  end

  describe "MapSet" do
    test "transforms keys of maps inside the set" do
      assert Keyable.transform_keys(MapSet.new([%{"a" => 1}]), &String.to_atom/1) ==
               MapSet.new([%{a: 1}])
    end

    test "an empty MapSet stays empty" do
      assert Keyable.transform_keys(MapSet.new(), &String.to_atom/1) == MapSet.new()
    end

    test "a MapSet of scalars passes through unchanged" do
      assert Keyable.transform_keys(MapSet.new([1, 2, 3]), &String.to_atom/1) ==
               MapSet.new([1, 2, 3])
    end
  end

  describe "Any (fallback)" do
    test "scalars, nil and structs pass through unchanged" do
      assert Keyable.transform_keys(nil, &String.to_atom/1) == nil
      assert Keyable.transform_keys(1, &String.to_atom/1) == 1
      assert Keyable.transform_keys("a string", &String.to_atom/1) == "a string"
      assert Keyable.transform_keys(true, &String.to_atom/1) == true
      assert Keyable.transform_keys(~D[2024-01-01], &String.to_atom/1) == ~D[2024-01-01]
    end
  end
end
