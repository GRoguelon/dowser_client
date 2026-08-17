defmodule Dowser.Client.NDJSONStubAdapter do
  @moduledoc false
  @behaviour Dowser.Client.JSON.Adapter

  @impl true
  def encode(:boom, _opts), do: {:error, :encode_boom}
  def encode(term, _opts), do: {:ok, "ENC(#{inspect(term)})"}

  @impl true
  def decode("boom", _opts), do: {:error, :decode_boom}
  def decode(line, _opts), do: {:ok, {:decoded, line}}
end

defmodule Dowser.Client.NDJSONTest do
  use ExUnit.Case, async: true

  doctest Dowser.Client.NDJSON

  alias Dowser.Client.NDJSON
  alias Dowser.Client.NDJSONStubAdapter, as: Stub

  # Full paths avoid aliasing Jason/Poison, which would shadow the real modules.
  @real_adapters [
    {Dowser.Client.JSON.Jason, Jason},
    {Dowser.Client.JSON.Poison, Poison}
  ]

  describe "delegation to the JSON adapter (stub)" do
    test "encode uses the adapter, joins with newlines, and appends a trailing newline" do
      assert {:ok, iodata} = NDJSON.encode([:a, :b], Stub)
      assert IO.iodata_to_binary(iodata) == "ENC(:a)\nENC(:b)\n"
    end

    test "decode uses the adapter, skips blank lines, and preserves order" do
      assert {:ok, [{:decoded, "l1"}, {:decoded, "l2"}]} = NDJSON.decode("l1\n\nl2\n", Stub)
    end

    test "encode short-circuits on the adapter's error" do
      assert {:error, :encode_boom} = NDJSON.encode([:a, :boom, :c], Stub)
    end

    test "decode short-circuits on the adapter's error" do
      assert {:error, :decode_boom} = NDJSON.decode("ok\nboom\nignored", Stub)
    end
  end

  describe "edge cases" do
    test "encoding an empty list yields empty iodata" do
      assert {:ok, iodata} = NDJSON.encode([], Stub)
      assert IO.iodata_to_binary(iodata) == ""
    end

    test "decoding empty or whitespace-only input yields an empty list" do
      assert {:ok, []} = NDJSON.decode("", Stub)
      assert {:ok, []} = NDJSON.decode("\n\n", Stub)
    end
  end

  describe "round-trip through real codecs" do
    for {adapter, backing} <- @real_adapters, Code.ensure_loaded?(backing) do
      test "#{inspect(adapter)} round-trips a bulk-style payload" do
        entries = [
          %{"index" => %{"_id" => "1"}},
          %{"title" => "hello", "views" => 2, "tags" => ["a", "b"]}
        ]

        assert {:ok, iodata} = NDJSON.encode(entries, unquote(adapter))
        binary = IO.iodata_to_binary(iodata)

        assert String.ends_with?(binary, "\n")
        assert binary |> String.trim_trailing("\n") |> String.split("\n") |> length() == 2

        assert {:ok, decoded} = NDJSON.decode(binary, unquote(adapter))
        assert decoded == entries
      end

      test "#{inspect(adapter)} propagates a decode error on malformed JSON" do
        assert {:error, _reason} = NDJSON.decode(~s({"ok":1}\n{broken), unquote(adapter))
      end
    end
  end
end
