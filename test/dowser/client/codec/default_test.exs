defmodule Dowser.Client.Codec.Default do
  use ExUnit.Case, async: true

  alias Dowser.Client.Codec.Default, as: DefaultCodec

  describe "encode/2" do
    test "returns the value unchanged, regardless of opts" do
      assert DefaultCodec.encode(%{"a" => 1}, key_fn: &String.to_atom/1) == {:ok, %{"a" => 1}}
      assert DefaultCodec.encode(nil, []) == {:ok, nil}
      assert DefaultCodec.encode([1, 2, 3], []) == {:ok, [1, 2, 3]}
    end
  end

  describe "decode/2" do
    test "applies :key_fn to a flat map's keys" do
      assert DefaultCodec.decode(%{"a" => 1, "b" => 2}, key_fn: &String.to_atom/1) ==
               {:ok, %{a: 1, b: 2}}
    end

    test "applies :key_fn recursively through nested maps" do
      assert DefaultCodec.decode(%{"a" => %{"b" => %{"c" => 1}}}, key_fn: &String.to_atom/1) ==
               {:ok, %{a: %{b: %{c: 1}}}}
    end

    # Regression: decode/2 used to guard on `is_map(map)`, so a top-level
    # *list* body (exactly what an ndjson response decodes to) skipped key
    # casting entirely.
    test "applies :key_fn to every map inside a top-level list (ndjson-shaped body)" do
      body = [%{"a" => 1}, %{"b" => 2}]

      assert DefaultCodec.decode(body, key_fn: &String.to_atom/1) == {:ok, [%{a: 1}, %{b: 2}]}
    end

    test "applies :key_fn through a list nested inside a map" do
      body = %{"items" => [%{"a" => 1}, %{"b" => 2}]}

      assert DefaultCodec.decode(body, key_fn: &String.to_atom/1) ==
               {:ok, %{items: [%{a: 1}, %{b: 2}]}}
    end

    test "applies :key_fn to a MapSet's elements" do
      body = MapSet.new([%{"a" => 1}])

      assert DefaultCodec.decode(body, key_fn: &String.to_atom/1) ==
               {:ok, MapSet.new([%{a: 1}])}
    end

    test "an empty map, empty list and nil all pass through unchanged" do
      assert DefaultCodec.decode(%{}, key_fn: &String.to_atom/1) == {:ok, %{}}
      assert DefaultCodec.decode([], key_fn: &String.to_atom/1) == {:ok, []}
      assert DefaultCodec.decode(nil, key_fn: &String.to_atom/1) == {:ok, nil}
    end

    test "scalar leaf values (numbers, booleans, binaries) pass through unchanged" do
      assert DefaultCodec.decode(%{"a" => 1, "b" => true, "c" => "x"}, key_fn: &String.to_atom/1) ==
               {:ok, %{a: 1, b: true, c: "x"}}
    end

    test ":strings (identity key_fn) leaves keys as-is" do
      assert DefaultCodec.decode(%{"a" => %{"b" => 1}}, key_fn: &Function.identity/1) ==
               {:ok, %{"a" => %{"b" => 1}}}
    end

    test "raises (uncaught) when :key_fn is missing from opts — callers are expected to always supply it" do
      assert_raise KeyError, fn -> DefaultCodec.decode(%{"a" => 1}, []) end
    end

    test ":atoms! propagates ArgumentError for an unknown atom" do
      assert_raise ArgumentError, fn ->
        DefaultCodec.decode(
          %{"definitely_not_an_existing_atom_xyz" => 1},
          key_fn: &String.to_existing_atom/1
        )
      end
    end
  end
end
