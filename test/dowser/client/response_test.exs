defmodule Dowser.Client.ResponseRaisingAdapter do
  @moduledoc false
  @behaviour Dowser.Client.JSON.Adapter

  @impl true
  def encode(term, _opts), do: {:ok, inspect(term)}

  @impl true
  def decode(_binary, _opts), do: raise("adapter blew up")
end

defmodule Dowser.Client.ResponseTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Codec.Error, as: CodecError
  alias Dowser.Client.Config
  alias Dowser.Client.FakeCodec
  alias Dowser.Client.JSON.Error, as: JSONError
  alias Dowser.Client.Request
  alias Dowser.Client.Response

  @json Dowser.Client.JSON.Native

  defp response(body), do: %Response{status: 200, body: body}

  # `Response.decode/2` takes the fully-resolved `%Request{}` built by
  # `Dowser.Client.Request.new/5` (rather than raw format/adapter/opts), so
  # tests build one through the real resolution pipeline via `request/1` and
  # only vary what each test cares about.
  defp request(opts \\ []) do
    config = Keyword.get(opts, :config, Config.new(endpoint: "http://x:9200"))
    request_opts = Keyword.drop(opts, [:config])

    assert {:ok, request} = Request.new(config, :get, "/", nil, request_opts)
    request
  end

  describe "new/3" do
    test "normalizes headers into a map of downcased string keys and string values" do
      response =
        Response.new(200, [{"Content-Type", "application/json"}, {~c"X-Custom", ~c"db"}], "")

      assert response.headers == %{"content-type" => "application/json", "x-custom" => "db"}
    end

    test "folds duplicate header names into a comma-joined value" do
      response = Response.new(200, [{"Warning", "a"}, {"warning", "b"}], "")

      assert response.headers == %{"warning" => "a, b"}
    end

    test "an empty header set yields an empty map" do
      assert Response.new(204, [], "").headers == %{}
    end
  end

  describe "decode/2" do
    test "json decodes the body" do
      assert Response.decode(response(~s({"ok":true})), request()) ==
               {:ok, response(%{"ok" => true})}
    end

    test "ndjson decodes the body into a list" do
      assert {:ok, %Response{body: [%{"a" => 1}, %{"b" => 2}]}} =
               Response.decode(response(~s({"a":1}\n{"b":2}\n)), request(format: :ndjson))
    end

    test "raw leaves the body untouched" do
      assert Response.decode(response("<html/>"), request(format: :raw)) ==
               {:ok, response("<html/>")}
    end

    test "empty and nil bodies pass through" do
      assert Response.decode(response(""), request()) == {:ok, response("")}
      assert Response.decode(response(nil), request()) == {:ok, response(nil)}
    end

    test "keeps status and headers intact while decoding the body" do
      response = %Response{status: 201, headers: [{"x", "y"}], body: ~s({"a":1})}

      assert {:ok, %Response{status: 201, headers: [{"x", "y"}], body: %{"a" => 1}}} =
               Response.decode(response, request())
    end

    test "a decode failure is wrapped in a JSON error" do
      assert {:error, %JSONError{operation: :decode, adapter: @json}} =
               Response.decode(response("{not json"), request())
    end

    test "an ndjson decode failure ({:error, reason} from the adapter) is wrapped in a JSON error" do
      assert {:error, %JSONError{operation: :decode, adapter: @json}} =
               Response.decode(response(~s({"ok":1}\n{broken)), request(format: :ndjson))
    end

    test "a raised (not returned) exception from json_adapter.decode/2 is wrapped in a JSON error" do
      assert {:error,
              %JSONError{operation: :decode, reason: %RuntimeError{message: "adapter blew up"}}} =
               Response.decode(
                 response(~s({"ok":true})),
                 request(json_adapter: Dowser.Client.ResponseRaisingAdapter)
               )
    end

    test "a raised (not returned) exception from the adapter is wrapped for ndjson too" do
      assert {:error,
              %JSONError{operation: :decode, reason: %RuntimeError{message: "adapter blew up"}}} =
               Response.decode(
                 response(~s({"ok":true}\n)),
                 request(format: :ndjson, json_adapter: Dowser.Client.ResponseRaisingAdapter)
               )
    end

    test "defaults to string keys" do
      assert {:ok, %Response{body: %{"a" => %{"b" => 1}}}} =
               Response.decode(response(~s({"a":{"b":1}})), request())
    end

    test "keys: :atoms casts every object key, however deeply nested" do
      assert {:ok, %Response{body: %{a: %{b: 1}}}} =
               Response.decode(response(~s({"a":{"b":1}})), request(keys: :atoms))
    end

    test "keys: :atoms casts keys inside list elements too" do
      assert {:ok, %Response{body: [%{a: 1}, %{b: 2}]}} =
               Response.decode(
                 response(~s({"a":1}\n{"b":2}\n)),
                 request(format: :ndjson, keys: :atoms)
               )
    end

    test "keys: :atoms! succeeds for a key that already exists as an atom" do
      _ = String.to_atom("response_test_existing_key")

      assert {:ok, %Response{body: %{response_test_existing_key: 1}}} =
               Response.decode(
                 response(~s({"response_test_existing_key":1})),
                 request(keys: :atoms!)
               )
    end

    # Key casting happens inside the (default) codec_adapter's decode/2, so a
    # raised ArgumentError from :atoms! is caught by Response's codec-cast
    # rescue and wrapped in a Codec.Error — not a JSON.Error, since JSON
    # decoding itself already succeeded by this point.
    test "keys: :atoms! wraps ArgumentError for an unknown atom in a Codec error" do
      assert {:error,
              %CodecError{
                operation: :decode,
                codec: Dowser.Client.Codec.Default,
                reason: %ArgumentError{}
              }} =
               Response.decode(
                 response(~s({"response_test_definitely_unknown_key":1})),
                 request(keys: :atoms!)
               )
    end

    test "with the default codec_adapter, keys are still cast per :keys" do
      assert Response.decode(response(~s({"ok":true})), request(keys: :atoms)) ==
               {:ok, response(%{ok: true})}
    end

    test "with the default codec_adapter, values are never cast (only keys)" do
      assert Response.decode(response(~s({"ok":true})), request()) ==
               {:ok, response(%{"ok" => true})}
    end

    # `codec_adapter: nil` isn't reachable through `Dowser.Client.Request.new/5`
    # (it always resolves a real module, defaulting to DefaultCodec) — this is
    # a defensive fallback in `Response`'s private `cast/2`, only reachable by
    # building a `%Request{}` directly. Pinned here so it isn't silently
    # dropped as "dead code".
    test "codec_adapter: nil (only reachable via a hand-built %Request{}) skips casting entirely" do
      raw_request = %{request() | codec_adapter: nil}

      assert Response.decode(response(~s({"ok":true})), raw_request) ==
               {:ok, response(%{"ok" => true})}
    end
  end

  describe "decode/2 codec_adapter" do
    test "invokes the configured codec_adapter's decode/2 with the decoded term and codec_opts" do
      fun = fn term, _opts -> Map.put(term, "cast", true) end

      assert Response.decode(
               response(~s({"ok":true})),
               request(codec_adapter: FakeCodec, codec_opts: [decode_fun: fun])
             ) == {:ok, response(%{"ok" => true, "cast" => true})}
    end

    test "codec_adapter receives :key_fn (resolved from :keys) and :config in opts" do
      config = Config.new(endpoint: "http://x:9200")

      fun = fn term, opts ->
        send(self(), {:decode_saw, opts[:key_fn].("k"), opts[:config]})
        term
      end

      assert {:ok, _} =
               Response.decode(
                 response(~s({"ok":true})),
                 request(
                   config: config,
                   codec_adapter: FakeCodec,
                   codec_opts: [decode_fun: fun],
                   keys: :atoms
                 )
               )

      assert_received {:decode_saw, :k, ^config}
    end

    test "codec_adapter casts keys itself in a single pass — dowser_client does not cast keys again afterward" do
      fun = fn term, _opts -> Map.new(term, fn {k, v} -> {String.upcase(k), v} end) end

      # FakeCodec above uppercases string keys instead of atomizing them; if
      # dowser_client ran its own key-cast pass afterward with keys: :atoms,
      # this would crash trying to atomize an already-cast key (or silently
      # double-cast). Neither happens — the codec's own output keys are
      # final.
      assert Response.decode(
               response(~s({"ok":true})),
               request(codec_adapter: FakeCodec, codec_opts: [decode_fun: fun], keys: :atoms)
             ) == {:ok, response(%{"OK" => true})}
    end

    test "the whole decoded ndjson list is handed to the codec at once (it handles per-element structure itself)" do
      fun = fn terms, _opts -> Enum.map(terms, &Map.put(&1, "cast", true)) end

      assert Response.decode(
               response(~s({"a":1}\n{"b":2}\n)),
               request(format: :ndjson, codec_adapter: FakeCodec, codec_opts: [decode_fun: fun])
             ) == {:ok, response([%{"a" => 1, "cast" => true}, %{"b" => 2, "cast" => true}])}
    end

    test "wraps a raised exception from the codec in a Codec.Error" do
      fun = fn _term, _opts -> raise "boom" end

      assert {:error, %CodecError{reason: %RuntimeError{message: "boom"}, operation: :decode}} =
               Response.decode(
                 response(~s({"ok":true})),
                 request(codec_adapter: FakeCodec, codec_opts: [decode_fun: fun])
               )
    end

    test "a codec exception while processing an ndjson body is wrapped in a Codec.Error" do
      fun = fn [%{"a" => 1} | _rest], _opts -> raise "bad_first" end

      assert {:error, %CodecError{reason: %RuntimeError{message: "bad_first"}}} =
               Response.decode(
                 response(~s({"a":1}\n{"b":2}\n)),
                 request(format: :ndjson, codec_adapter: FakeCodec, codec_opts: [decode_fun: fun])
               )
    end
  end
end
