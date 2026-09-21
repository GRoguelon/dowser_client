defmodule Dowser.Client.DecoderTestModuleDecoder do
  @moduledoc false

  def decode(body, opts), do: Map.put(body, "mapping", opts[:mapping])
end

defmodule Dowser.Client.DecoderTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Decoder

  describe "key_fun/1" do
    test ":strings and nil cast nothing, so there is no function to run" do
      assert Decoder.key_fun(:strings) == {:ok, nil}
      assert Decoder.key_fun(nil) == {:ok, nil}
    end

    test ":atoms and :atoms! resolve to the matching String functions" do
      assert {:ok, fun} = Decoder.key_fun(:atoms)
      assert fun.("decoder_test_new_key") == :decoder_test_new_key

      assert Decoder.key_fun(:atoms!) == {:ok, &String.to_existing_atom/1}
    end

    test "a function of arity 1 is taken as-is" do
      assert {:ok, fun} = Decoder.key_fun(&String.upcase/1)
      assert fun.("a") == "A"
    end

    test "anything else is an error" do
      assert Decoder.key_fun(:camel_case) == {:error, {:invalid_keys, :camel_case}}
      assert {:error, {:invalid_keys, _fun}} = Decoder.key_fun(fn _a, _b -> :nope end)
    end
  end

  describe "suggestion/1" do
    test "offers the nearest :keys value for a typo" do
      assert Decoder.suggestion(:atom) == :atoms
      assert Decoder.suggestion(:atom!) == :atoms!
      assert Decoder.suggestion(:string) == :strings
      assert Decoder.suggestion("strings") == :strings
    end

    test "offers nothing when nothing is close" do
      assert Decoder.suggestion(:camel_case) == nil
      assert Decoder.suggestion(fn -> :nope end) == nil
    end
  end

  describe "decoder/1" do
    test "nil means no decoder" do
      assert Decoder.decoder(nil) == {:ok, nil}
    end

    test "a function of arity 2 resolves with no options" do
      fun = fn body, _opts -> body end

      assert Decoder.decoder(fun) == {:ok, {fun, []}}
    end

    test "a module exporting decode/2 is wrapped into a function" do
      assert {:ok, {fun, []}} = Decoder.decoder(Dowser.Client.DecoderTestModuleDecoder)

      assert fun.(%{"a" => 1}, mapping: :m) == %{"a" => 1, "mapping" => :m}
    end

    test "a module can be paired with the options it needs" do
      assert {:ok, {fun, mapping: :m}} =
               Decoder.decoder({Dowser.Client.DecoderTestModuleDecoder, mapping: :m})

      assert is_function(fun, 2)
    end

    test "a function can be paired with the options it needs" do
      fun = fn body, _opts -> body end

      assert Decoder.decoder({fun, mapping: :m}) == {:ok, {fun, mapping: :m}}
    end

    test "a module without decode/2 is an error, paired or not" do
      assert Decoder.decoder(String) == {:error, {:invalid_decoder, String}}
      assert Decoder.decoder(NotAModule) == {:error, {:invalid_decoder, NotAModule}}
      assert Decoder.decoder({String, mapping: :m}) == {:error, {:invalid_decoder, String}}
    end

    test "options that aren't a keyword list are an error" do
      decoder = Dowser.Client.DecoderTestModuleDecoder

      assert Decoder.decoder({decoder, "nope"}) ==
               {:error, {:invalid_decoder, {decoder, "nope"}}}
    end

    test "any other arity, or a non-function, is an error" do
      assert Decoder.decoder(:nope) == {:error, {:invalid_decoder, :nope}}
      assert {:error, {:invalid_decoder, _fun}} = Decoder.decoder(fn body -> body end)
    end
  end

  describe "needed?/2" do
    test "true as soon as either half is configured" do
      refute Decoder.needed?(nil, nil)
      assert Decoder.needed?(&Function.identity/1, nil)
      assert Decoder.needed?(nil, {fn body, _opts -> body end, []})
    end
  end

  describe "run/3 with keys only" do
    test "casts keys through maps, lists and MapSets" do
      body = %{
        "a" => 1,
        "nested" => %{"b" => 2},
        "list" => [%{"c" => 3}, [%{"d" => 4}]],
        "set" => MapSet.new([%{"e" => 5}])
      }

      assert Decoder.run(body, &String.to_atom/1, nil) == %{
               a: 1,
               nested: %{b: 2},
               list: [%{c: 3}, [%{d: 4}]],
               set: MapSet.new([%{e: 5}])
             }
    end

    test "leaves values, non-binary keys and structs alone" do
      body = %{1 => "a", "d" => ~D[2026-09-18], "s" => "2026-09-18"}

      assert Decoder.run(body, &String.to_atom/1, nil) == %{
               1 => "a",
               d: ~D[2026-09-18],
               s: "2026-09-18"
             }
    end

    test "no key function and no decoder leaves the body exactly as it was" do
      assert Decoder.run(%{"a" => 1}, nil, nil) == %{"a" => 1}
    end
  end

  describe "run/3 with a nil body" do
    # A JSON `null` decodes to nil, and there is nothing in it to cast — so a
    # decoder never has to guard against it.
    test "the decoder is never called, whatever is configured" do
      loud = {fn _body, _opts -> raise "never called" end, []}

      assert Decoder.run(nil, &String.to_atom/1, loud) == nil
      assert Decoder.run(nil, nil, loud) == nil
    end

    test "key casting is skipped too" do
      assert Decoder.run(nil, &String.to_atom/1, nil) == nil
      assert Decoder.run(nil, nil, nil) == nil
    end
  end

  describe "run/3 with a decoder" do
    test "hands the whole body over, with its own options and :key_fn" do
      decoder = fn body, opts ->
        send(self(), {:decoded, body, opts})

        :replaced
      end

      assert Decoder.run(%{"a" => 1}, &String.to_atom/1, {decoder, mapping: :some_mapping}) ==
               :replaced

      assert_received {:decoded, %{"a" => 1}, opts}
      assert opts[:mapping] == :some_mapping
      assert opts[:key_fn].("k") == :k
    end

    test ":key_fn is Function.identity/1 when :keys casts nothing" do
      decoder = fn body, opts -> Map.put(body, "probe", opts[:key_fn].("k")) end

      assert Decoder.run(%{"a" => 1}, nil, {decoder, []}) == %{"a" => 1, "probe" => "k"}
    end

    # The decoder owns the body: dowser_client does not cast keys before or
    # after it, which is why it is handed the key function.
    test "the decoder's output is final — keys are not cast around it" do
      decoder = fn _body, _opts -> %{"left" => "alone"} end

      assert Decoder.run(%{"a" => 1}, &String.to_atom/1, {decoder, []}) == %{"left" => "alone"}
    end
  end

  # `dowser_client` knows nothing about `_source`, `_index`, or any other
  # engine's envelope. This is the decoder `dowser_elasticsearch` supplies,
  # written here to pin the contract it relies on.
  describe "worked example: an Elasticsearch decoder, supplied by the backend" do
    @mappings %{
      "articles" => %{
        "properties" => %{
          "title" => %{"type" => "text"},
          "published_at" => %{"type" => "date"},
          "run_window" => %{"type" => "date_range"}
        }
      }
    }

    defp decode(body, opts) do
      key_fn = Keyword.fetch!(opts, :key_fn)

      do_decode(body, key_fn)
    end

    # A hit carries the index it came from, so its mapping can be resolved and
    # the document cast field by field.
    defp do_decode(%{"_index" => index, "_source" => _source} = hit, key_fn) do
      Map.new(hit, fn
        {"_source" = key, source} -> {key_fn.(key), decode_source(source, index, key_fn)}
        {key, value} -> {key_fn.(key), do_decode(value, key_fn)}
      end)
    end

    defp do_decode(value, key_fn) when is_non_struct_map(value) do
      Map.new(value, fn {key, value} -> {key_fn.(key), do_decode(value, key_fn)} end)
    end

    defp do_decode(value, key_fn) when is_list(value) do
      Enum.map(value, &do_decode(&1, key_fn))
    end

    defp do_decode(value, _key_fn), do: value

    defp decode_source(source, index, key_fn) do
      %{"properties" => properties} = Map.fetch!(@mappings, index)

      Enum.reduce(properties, %{}, fn {field, options}, acc ->
        case Map.fetch(source, field) do
          {:ok, value} -> Map.put(acc, key_fn.(field), load(value, options))
          :error -> acc
        end
      end)
    end

    defp load(value, %{"type" => "date"}) when is_binary(value) do
      case Date.from_iso8601(value) do
        {:ok, date} -> date
        {:error, _reason} -> value
      end
    end

    # An Elasticsearch range value is an object of bounds:
    # %{"gte" => "2026-09-01", "lt" => "2026-10-01"}
    defp load(value, %{"type" => "date_range"}) when is_map(value) do
      Map.new(value, fn {bound, bound_value} ->
        {bound, load(bound_value, %{"type" => "date"})}
      end)
    end

    defp load(value, _options), do: value

    test "casts date and date_range fields of each hit against its own index" do
      body = %{
        "took" => 5,
        "hits" => %{
          "total" => %{"value" => 1},
          "hits" => [
            %{
              "_index" => "articles",
              "_id" => "1",
              "_source" => %{
                "title" => "hello",
                "published_at" => "2026-09-18",
                "run_window" => %{"gte" => "2026-09-01", "lt" => "2026-10-01"},
                "not_in_mapping" => "dropped"
              }
            }
          ]
        }
      }

      assert Decoder.run(body, &String.to_atom/1, {&decode/2, []}) == %{
               took: 5,
               hits: %{
                 total: %{value: 1},
                 hits: [
                   %{
                     _index: "articles",
                     _id: "1",
                     _source: %{
                       title: "hello",
                       published_at: ~D[2026-09-18],
                       run_window: %{"gte" => ~D[2026-09-01], "lt" => ~D[2026-10-01]}
                     }
                   }
                 ]
               }
             }
    end

    test "with keys: :strings the same decoder leaves keys as strings" do
      body = %{"_index" => "articles", "_source" => %{"published_at" => "2026-09-18"}}

      assert Decoder.run(body, nil, {&decode/2, []}) == %{
               "_index" => "articles",
               "_source" => %{"published_at" => ~D[2026-09-18]}
             }
    end

    test "a malformed date is left as the string the backend sent" do
      body = %{"_index" => "articles", "_source" => %{"published_at" => "not-a-date"}}

      assert Decoder.run(body, nil, {&decode/2, []}) == %{
               "_index" => "articles",
               "_source" => %{"published_at" => "not-a-date"}
             }
    end
  end
end
