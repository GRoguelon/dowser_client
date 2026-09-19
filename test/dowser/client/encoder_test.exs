defmodule Dowser.Client.EncoderTestModuleEncoder do
  @moduledoc false

  def encode(source, opts), do: Map.put(source, "index", opts[:index])
end

defmodule Dowser.Client.EncoderTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Encoder

  describe "encoder/1" do
    test "nil means no encoder" do
      assert Encoder.encoder(nil) == {:ok, nil}
    end

    test "a function of arity 2 resolves with no options" do
      fun = fn source, _opts -> source end

      assert Encoder.encoder(fun) == {:ok, {fun, []}}
    end

    test "a module exporting encode/2 is wrapped into a function" do
      assert {:ok, {fun, []}} = Encoder.encoder(Dowser.Client.EncoderTestModuleEncoder)

      assert fun.(%{"a" => 1}, index: "articles") == %{"a" => 1, "index" => "articles"}
    end

    test "a module can be paired with the options it needs" do
      assert {:ok, {fun, index: "articles"}} =
               Encoder.encoder({Dowser.Client.EncoderTestModuleEncoder, index: "articles"})

      assert is_function(fun, 2)
    end

    test "a function can be paired with the options it needs" do
      fun = fn source, _opts -> source end

      assert Encoder.encoder({fun, index: "articles"}) == {:ok, {fun, index: "articles"}}
    end

    test "an empty option list is fine" do
      assert {:ok, {_fun, []}} = Encoder.encoder({Dowser.Client.EncoderTestModuleEncoder, []})
    end

    test "a module without encode/2 is an error, paired or not" do
      assert Encoder.encoder(String) == {:error, {:invalid_encoder, String}}
      assert Encoder.encoder(NotAModule) == {:error, {:invalid_encoder, NotAModule}}
      assert Encoder.encoder({String, index: "x"}) == {:error, {:invalid_encoder, String}}
    end

    test "options that aren't a keyword list are an error" do
      encoder = Dowser.Client.EncoderTestModuleEncoder

      assert Encoder.encoder({encoder, "nope"}) ==
               {:error, {:invalid_encoder, {encoder, "nope"}}}

      assert Encoder.encoder({encoder, [1, 2]}) ==
               {:error, {:invalid_encoder, {encoder, [1, 2]}}}
    end

    test "any other arity, or a non-function, is an error" do
      assert {:error, {:invalid_encoder, _fun}} = Encoder.encoder(fn source -> source end)
      assert Encoder.encoder("nope") == {:error, {:invalid_encoder, "nope"}}
    end
  end

  describe "encode/1" do
    test "false and nil mean nothing is encoded" do
      assert Encoder.encode(nil) == {:ok, :skip}
      assert Encoder.encode(false) == {:ok, :skip}
    end

    test "true means the body is the source" do
      assert Encoder.encode(true) == {:ok, :root}
      assert Encoder.encode([]) == {:ok, :root}
    end

    test "a path is one place to encode at" do
      assert Encoder.encode(["doc"]) == {:ok, {:paths, [["doc"]]}}
      assert Encoder.encode(["a", "b"]) == {:ok, {:paths, [["a", "b"]]}}
    end

    test "a list of paths is several" do
      assert Encoder.encode([["doc"], ["upsert"]]) == {:ok, {:paths, [["doc"], ["upsert"]]}}
    end

    test "anything else is an error" do
      assert Encoder.encode(:root) == {:error, {:invalid_encode, :root}}
      assert Encoder.encode("doc") == {:error, {:invalid_encode, "doc"}}
    end
  end

  describe "run/3" do
    defp encoder(opts \\ []) do
      {fn source, opts -> Map.put(source, "seen", opts[:index]) end, opts}
    end

    test "no encoder leaves the body untouched, whatever :encode says" do
      assert Encoder.run(%{"a" => 1}, nil, :root) == %{"a" => 1}
      assert Encoder.run(%{"a" => 1}, nil, {:paths, [["doc"]]}) == %{"a" => 1}
    end

    test "a nil body skips the encoder, whatever :encode says" do
      loud = {fn _source, _opts -> raise "never called" end, []}

      assert Encoder.run(nil, loud, :root) == nil
      assert Encoder.run(nil, loud, {:paths, [["doc"]]}) == nil
      assert Encoder.run(nil, nil, :root) == nil
    end

    test "a source present but nil is skipped, so the encoder never sees nil" do
      loud = {fn _source, _opts -> raise "never called" end, []}

      assert Encoder.run(%{"doc" => nil}, loud, {:paths, [["doc"]]}) == %{"doc" => nil}
    end

    test ":skip leaves the body untouched" do
      assert Encoder.run(%{"a" => 1}, encoder(), :skip) == %{"a" => 1}
    end

    test ":root hands the whole body over, with the encoder's own options" do
      assert Encoder.run(%{"a" => 1}, encoder(index: "articles"), :root) == %{
               "a" => 1,
               "seen" => "articles"
             }
    end

    test "the encoder receives exactly the options it was configured with" do
      encoder = {fn source, opts -> Map.put(source, "opts", Map.new(opts)) end, index: "own"}

      assert Encoder.run(%{}, encoder, :root) == %{"opts" => %{index: "own"}}
    end

    test "a path encodes only what sits under it" do
      body = %{"doc" => %{"a" => 1}, "doc_as_upsert" => true}

      assert Encoder.run(body, encoder(index: "articles"), {:paths, [["doc"]]}) == %{
               "doc" => %{"a" => 1, "seen" => "articles"},
               "doc_as_upsert" => true
             }
    end

    test "several paths each get encoded" do
      body = %{"doc" => %{"a" => 1}, "upsert" => %{"b" => 2}}

      assert Encoder.run(body, encoder(), {:paths, [["doc"], ["upsert"]]}) == %{
               "doc" => %{"a" => 1, "seen" => nil},
               "upsert" => %{"b" => 2, "seen" => nil}
             }
    end

    test "a nested path works" do
      body = %{"script" => %{"params" => %{"a" => 1}}}

      assert Encoder.run(body, encoder(), {:paths, [["script", "params"]]}) == %{
               "script" => %{"params" => %{"a" => 1, "seen" => nil}}
             }
    end

    # `update_in/3` would insert the key; a path pointing at nothing must leave
    # the body alone instead.
    test "a path that isn't there is skipped, not created" do
      assert Encoder.run(%{"a" => 1}, encoder(), {:paths, [["doc"]]}) == %{"a" => 1}
      assert Encoder.run(%{"a" => 1}, encoder(), {:paths, [["doc", "deep"]]}) == %{"a" => 1}
    end

    test "Access functions reach into a list, for a bulk body" do
      bulk = [%{"index" => %{"_id" => "1"}}, %{"a" => 1}]

      assert Encoder.run(bulk, encoder(), {:paths, [[Access.at(1)]]}) == [
               %{"index" => %{"_id" => "1"}},
               %{"a" => 1, "seen" => nil}
             ]
    end
  end

  # What `dowser_elasticsearch` is expected to supply: one encoder for document
  # sources, driven by the mapping of the index being written to. Queries are
  # never encoded — too many shapes mean too many answers for one value.
  describe "worked example: an Elasticsearch source encoder" do
    @mappings %{
      "articles" => %{
        "properties" => %{
          "published_at" => %{"type" => "date", "format" => "strict_date"},
          "run_window" => %{"type" => "date_range"}
        }
      }
    }

    defp encode(source, opts) do
      %{"properties" => properties} = Map.fetch!(@mappings, Keyword.fetch!(opts, :index))

      Map.new(source, fn {field, value} -> {field, dump(value, properties[field])} end)
    end

    defp dump(%Date{} = date, %{"type" => "date", "format" => "strict_date"}) do
      Date.to_iso8601(date)
    end

    defp dump(%Date.Range{first: first, last: last}, %{"type" => "date_range"}) do
      %{"gte" => Date.to_iso8601(first), "lte" => Date.to_iso8601(last)}
    end

    defp dump(value, _field), do: value

    test "a whole document, indexed" do
      document = %{
        "title" => "hello",
        "published_at" => ~D[2026-09-19],
        "run_window" => Date.range(~D[2026-09-01], ~D[2026-09-30])
      }

      assert Encoder.run(document, {&encode/2, index: "articles"}, :root) == %{
               "title" => "hello",
               "published_at" => "2026-09-19",
               "run_window" => %{"gte" => "2026-09-01", "lte" => "2026-09-30"}
             }
    end

    test "a partial update, where the source sits under the doc key" do
      body = %{"doc" => %{"published_at" => ~D[2026-09-19]}, "doc_as_upsert" => true}

      assert Encoder.run(body, {&encode/2, index: "articles"}, {:paths, [["doc"]]}) == %{
               "doc" => %{"published_at" => "2026-09-19"},
               "doc_as_upsert" => true
             }
    end

    test "an upsert, with a source in each of two places" do
      body = %{
        "doc" => %{"published_at" => ~D[2026-09-19]},
        "upsert" => %{"published_at" => ~D[2026-01-01], "title" => "new"}
      }

      assert Encoder.run(body, {&encode/2, index: "articles"}, {:paths, [["doc"], ["upsert"]]}) ==
               %{
                 "doc" => %{"published_at" => "2026-09-19"},
                 "upsert" => %{"published_at" => "2026-01-01", "title" => "new"}
               }
    end
  end
end
