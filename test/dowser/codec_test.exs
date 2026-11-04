defmodule Dowser.CodecTest do
  use ExUnit.Case, async: false

  alias Dowser.Codec
  alias Dowser.Repo.Config
  alias Dowser.TestPost

  # A backend's configuration: mappings come from Dowser.TestMappings, standing
  # in for a cluster's mapping cacher.
  @config %{otp_app: :dowser_client, cacher: Dowser.TestMappings, opaque: []}

  @hit_body %{
    "hits" => %{
      "hits" => [
        %{
          "_index" => "posts",
          "_id" => "1",
          "_seq_no" => 4,
          "_source" => %{"title" => "hi", "published_at" => "2026-08-11T00:00:00.000Z"}
        }
      ]
    }
  }

  defp decode(body, opts), do: Codec.decode(body, Keyword.put_new(opts, :key_fn, & &1), @config)

  setup do
    on_exit(fn ->
      for key <- [:types, :unknown_fields, :codec, :mapping] do
        Application.delete_env(:dowser_client, key)
      end
    end)
  end

  describe ":mapping" do
    test "defaults to the backend's mapping source" do
      body = %{"_index" => "posts", "_source" => %{"ip" => "127.0.0.1"}}

      assert %{"_source" => %{"ip" => {127, 0, 0, 1}}} = decode(body, [])
    end

    test "a map is the mapping itself, whatever the index" do
      body = %{"_index" => "other", "_source" => %{"ip" => "127.0.0.1"}}
      mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}

      assert %{"_source" => %{"ip" => {127, 0, 0, 1}}} = decode(body, mapping: mapping)
    end

    test "a Dowser.Mapping module is asked for each index" do
      body = %{"_index" => "posts", "_source" => %{"ip" => "127.0.0.1"}}

      assert %{"_source" => %{"ip" => {127, 0, 0, 1}}} =
               decode(body, mapping: Dowser.TestMappings)
    end

    test "a document module's own mapping casts, but documents stay maps" do
      assert %{"hits" => %{"hits" => [%{"_source" => source}]}} =
               decode(@hit_body, mapping: TestPost)

      assert source == %{"title" => "hi", "published_at" => ~U[2026-08-11 00:00:00.000Z]}
    end

    test "the application environment sets the default source" do
      Application.put_env(:dowser_client, :mapping, %{
        "properties" => %{"ip" => %{"type" => "ip"}}
      })

      on_exit(fn -> Application.delete_env(:dowser_client, :mapping) end)

      body = %{"_index" => "anything", "_source" => %{"ip" => "127.0.0.1"}}

      assert %{"_source" => %{"ip" => {127, 0, 0, 1}}} = decode(body, [])

      # :struct casts against its own mapping, whatever the application sets.
      assert %{"hits" => %{"hits" => [%{"_source" => %TestPost{}}]}} =
               decode(@hit_body, struct: TestPost)
    end

    test "a mapping cacher that isn't started is a failure, not a silent identity" do
      config = %{@config | cacher: Dowser.TestCacher}
      body = %{"_index" => "posts", "_source" => %{"ip" => "127.0.0.1"}}
      repo_config = Config.new(endpoint: "http://x:9200")

      error =
        assert_raise Dowser.MappingError, fn ->
          Codec.decode(body, [key_fn: & &1, repo_config: repo_config], config)
        end

      assert error.reason == {:not_started, Dowser.TestCacher}
      assert Exception.message(error) =~ "Dowser.TestCacher is not started"

      start_supervised!({Dowser.TestCacher, fetch: fn _config, _index -> {:ok, nil} end})

      assert %{"_source" => %{"ip" => "127.0.0.1"}} =
               Codec.decode(body, [key_fn: & &1, repo_config: repo_config], config)
    end

    test "a failed fetch goes through :mapping_failure" do
      body = %{"_index" => "broken", "_source" => %{"ip" => "127.0.0.1"}}

      assert_raise Dowser.MappingError, fn -> decode(body, []) end

      assert %{"_source" => %{"ip" => "127.0.0.1"}} = decode(body, mapping_failure: :ignore)
    end
  end

  describe ":struct" do
    test "loads every hit's source into the struct, with the hit's metadata" do
      assert %{"hits" => %{"hits" => [%{"_id" => "1", "_source" => %TestPost{} = post}]}} =
               decode(@hit_body, struct: TestPost)

      assert post.title == "hi"
      assert post.published_at == ~U[2026-08-11 00:00:00.000Z]
      assert post.meta == %{"_index" => "posts", "_id" => "1", "_seq_no" => 4}
    end

    test ":key_fn casts the envelope's keys, never the struct's loader input" do
      assert %{hits: %{hits: [%{_id: "1", _source: %TestPost{title: "hi"} = post}]}} =
               decode(@hit_body, struct: TestPost, key_fn: &String.to_atom/1)

      assert post.published_at == ~U[2026-08-11 00:00:00.000Z]
      assert post.meta == %{"_index" => "posts", "_id" => "1", "_seq_no" => 4}
    end

    test "loads a bare source, with the request's index as its metadata" do
      body = %{"title" => "hi", "published_at" => "2026-08-11T00:00:00.000Z"}

      assert %TestPost{title: "hi", meta: %{"_index" => "posts"}} =
               decode(body, struct: TestPost, source: true, index: "posts")
    end

    test "dumps the struct, and a map of its fields against its mapping" do
      post = %TestPost{title: "hi", published_at: ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(post, [struct: TestPost], @config) == %{
               "title" => "hi",
               "published_at" => "2026-08-11T00:00:00.000Z"
             }

      assert Codec.encode(
               %{"published_at" => ~U[2026-08-11 00:00:00Z]},
               [struct: TestPost],
               @config
             ) ==
               %{"published_at" => "2026-08-11T00:00:00.000Z"}
    end

    test "with the same module as :mapping is fine, with another is an error" do
      assert %{"hits" => _hits} = decode(@hit_body, struct: TestPost, mapping: TestPost)

      assert_raise ArgumentError, ~r/casts against its own mapping/, fn ->
        decode(@hit_body, struct: TestPost, mapping: %{})
      end
    end

    test "must be a document module" do
      assert_raise ArgumentError, ~r/is not a document module/, fn ->
        decode(@hit_body, struct: URI)
      end
    end
  end

  describe ":types" do
    test "names the type module, per request then from the application environment" do
      body = %{"_index" => "x", "_source" => %{"title" => "hi"}}
      mapping = %{"properties" => %{"title" => %{"type" => "text"}}}

      assert %{"_source" => %{"title" => "hi"}} = decode(body, mapping: mapping)

      assert %{"_source" => %{"title" => "HI"}} =
               decode(body, mapping: mapping, types: Dowser.TestUpcase)

      Application.put_env(:dowser_client, :types, Dowser.TestUpcase)
      assert %{"_source" => %{"title" => "HI"}} = decode(body, mapping: mapping)
    end

    test "the removed :codec is an error naming :types, per request or configured" do
      assert_raise ArgumentError, ~r/the :codec option is now :types/, fn ->
        decode(@hit_body, codec: Dowser.TestUpcase)
      end

      Application.put_env(:dowser_client, :codec, Dowser.TestUpcase)

      assert_raise ArgumentError, ~r/the :codec option is now :types/, fn ->
        decode(@hit_body, [])
      end
    end
  end

  describe ":unknown_fields" do
    @extra %{"_index" => "posts", "_source" => %{"ip" => "127.0.0.1", "extra" => 1}}

    test "keeps a field the mapping doesn't declare by default" do
      assert %{"_source" => %{"extra" => 1}} = decode(@extra, [])
    end

    test ":raise raises, per request or from the application environment" do
      assert_raise Dowser.UnknownFieldError, ~r/field "extra" is not in the mapping/, fn ->
        decode(@extra, unknown_fields: :raise)
      end

      Application.put_env(:dowser_client, :unknown_fields, :raise)

      assert_raise Dowser.UnknownFieldError, fn -> decode(@extra, []) end
    end

    test "applies when dumping too" do
      assert_raise Dowser.UnknownFieldError, ~r/dumping/, fn ->
        Codec.encode(%{"extra" => 1}, [index: "posts", unknown_fields: :raise], @config)
      end
    end
  end
end
