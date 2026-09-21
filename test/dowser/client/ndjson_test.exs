defmodule Dowser.Client.NDJSONTest do
  use ExUnit.Case, async: true

  doctest Dowser.Client.NDJSON

  alias Dowser.Client.JSON.Error
  alias Dowser.Client.NDJSON

  describe "encode/1" do
    test "joins entries with newlines and appends a trailing newline" do
      assert {:ok, iodata} = NDJSON.encode([%{"a" => 1}, %{"b" => 2}])
      assert IO.iodata_to_binary(iodata) == ~s({"a":1}\n{"b":2}\n)
    end

    test "an empty list yields empty iodata" do
      assert {:ok, iodata} = NDJSON.encode([])
      assert IO.iodata_to_binary(iodata) == ""
    end

    test "short-circuits on the first entry that cannot be encoded" do
      assert {:error, %Error{operation: :encode}} =
               NDJSON.encode([%{"a" => 1}, {:not, :json}, %{"c" => 3}])
    end
  end

  describe "decode/1" do
    test "decodes one term per line, in order, with string keys" do
      assert {:ok, [%{"a" => 1}, %{"b" => 2}]} = NDJSON.decode(~s({"a":1}\n{"b":2}\n))
    end

    test "skips blank lines" do
      assert {:ok, [%{"a" => 1}, %{"b" => 2}]} = NDJSON.decode(~s({"a":1}\n\n{"b":2}\n))
    end

    test "empty or whitespace-only input yields an empty list" do
      assert {:ok, []} = NDJSON.decode("")
      assert {:ok, []} = NDJSON.decode("\n\n")
    end

    test "short-circuits on the first malformed line" do
      assert {:error, %Error{operation: :decode}} =
               NDJSON.decode(~s({"ok":1}\n{broken\n{"ignored":2}))
    end
  end

  describe "encode/2 casting options" do
    test ":encoder and :encode are applied per entry, not over the whole list" do
      encoder = {fn entry, opts -> Map.put(entry, "seen", opts[:index]) end, index: "articles"}

      assert {:ok, iodata} =
               NDJSON.encode([%{"a" => 1}, %{"b" => 2}], encoder: encoder, encode: :root)

      assert IO.iodata_to_binary(iodata) ==
               ~s({"a":1,"seen":"articles"}\n{"b":2,"seen":"articles"}\n)
    end

    # This is why per-entry matters: a bulk payload alternates action lines and
    # documents, and the encoder can tell them apart one line at a time.
    test "an encoder can pass action lines through and cast only documents" do
      encoder =
        {fn
           %{"index" => _action} = action, _opts -> action
           document, _opts -> Map.put(document, "cast", true)
         end, []}

      entries = [%{"index" => %{"_id" => "1"}}, %{"title" => "a"}]

      assert {:ok, iodata} = NDJSON.encode(entries, encoder: encoder, encode: :root)

      assert IO.iodata_to_binary(iodata) ==
               ~s({"index":{"_id":"1"}}\n{"cast":true,"title":"a"}\n)
    end

    test "a path applies within each entry, skipping lines that don't have it" do
      encoder = {fn source, _opts -> Map.put(source, "cast", true) end, []}
      entries = [%{"update" => %{"_id" => "1"}}, %{"doc" => %{"t" => "x"}}]

      assert {:ok, iodata} =
               NDJSON.encode(entries, encoder: encoder, encode: {:paths, [["doc"]]})

      assert IO.iodata_to_binary(iodata) ==
               ~s({"update":{"_id":"1"}}\n{"doc":{"cast":true,"t":"x"}}\n)
    end

    test "no encoder leaves every entry as it was" do
      assert {:ok, iodata} = NDJSON.encode([%{"a" => 1}], encoder: nil, encode: :root)
      assert IO.iodata_to_binary(iodata) == ~s({"a":1}\n)
    end

    # `Request.new/5`'s contract is a result tuple, so a body with no NDJSON
    # representation must not raise out of the guard clause.
    test "a body that isn't a list is an error, not a crash" do
      assert {:error, %Dowser.Client.Error{reason: {:invalid_ndjson, %{"a" => 1}}} = error} =
               NDJSON.encode(%{"a" => 1})

      assert Exception.message(error) =~ "must be a list of terms"

      assert {:error, %Dowser.Client.Error{reason: {:invalid_ndjson, "nope"}}} =
               NDJSON.encode("nope")
    end
  end

  describe "decode/2 casting options" do
    test ":key_fn is applied per entry" do
      assert {:ok, [%{a: 1}, %{b: 2}]} =
               NDJSON.decode(~s({"a":1}\n{"b":2}\n), key_fn: &String.to_atom/1)
    end

    test ":decoder is applied per entry, with :key_fn in its options" do
      decoder = {fn entry, opts -> Map.put(entry, opts[:key_fn].("line"), true) end, []}

      assert {:ok, [first, second]} =
               NDJSON.decode(~s({"a":1}\n{"b":2}\n),
                 key_fn: &String.to_atom/1,
                 decoder: decoder
               )

      assert first == %{:line => true, "a" => 1}
      assert second == %{:line => true, "b" => 2}
    end

    test "no options leaves every entry as JSON decoded it" do
      assert {:ok, [%{"a" => 1}]} = NDJSON.decode(~s({"a":1}\n), key_fn: nil, decoder: nil)
    end
  end

  describe "round-trip" do
    test "a bulk-style payload survives encode/decode" do
      entries = [
        %{"index" => %{"_id" => "1"}},
        %{"title" => "hello", "views" => 2, "tags" => ["a", "b"]}
      ]

      assert {:ok, iodata} = NDJSON.encode(entries)
      binary = IO.iodata_to_binary(iodata)

      assert String.ends_with?(binary, "\n")
      assert binary |> String.trim_trailing("\n") |> String.split("\n") |> length() == 2
      assert {:ok, ^entries} = NDJSON.decode(binary)
    end
  end
end
