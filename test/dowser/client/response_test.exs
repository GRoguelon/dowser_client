defmodule Dowser.Client.ResponseTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Context
  alias Dowser.Client.Error
  alias Dowser.Client.JSON.Error, as: JSONError
  alias Dowser.Client.Request
  alias Dowser.Client.Response

  defp response(body), do: %Response{status: 200, body: body}

  # `Response.decode/2` takes the fully-resolved `%Request{}` built by
  # `Dowser.Client.Request.new/5` (rather than raw format/codec/opts), so
  # tests build one through the real resolution pipeline via `request/1` and
  # only vary what each test cares about.
  defp request(opts \\ []) do
    context = Keyword.get(opts, :context, Context.new(endpoint: "http://x:9200"))
    request_opts = Keyword.drop(opts, [:context])

    assert {:ok, request} = Request.new(context, :get, "/", nil, request_opts)
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
      assert {:error, %JSONError{operation: :decode}} =
               Response.decode(response("{not json"), request())
    end

    test "an ndjson decode failure is wrapped in a JSON error" do
      assert {:error, %JSONError{operation: :decode}} =
               Response.decode(response(~s({"ok":1}\n{broken)), request(format: :ndjson))
    end

    test "keys are always strings, however deeply nested — casting them is the codec's job" do
      assert {:ok, %Response{body: %{"a" => %{"b" => [%{"c" => 1}]}}}} =
               Response.decode(response(~s({"a":{"b":[{"c":1}]}})), request())
    end

    test "no :keys or :decoder means no second pass at all" do
      assert Response.decode(response(~s({"ok":true,"date":"2026-09-18"})), request()) ==
               {:ok, response(%{"ok" => true, "date" => "2026-09-18"})}
    end
  end

  describe "decode/2 second pass" do
    test "keys: :atoms casts every key, however deeply nested" do
      assert {:ok, %Response{body: %{a: %{b: [%{c: 1}]}}}} =
               Response.decode(response(~s({"a":{"b":[{"c":1}]}})), request(keys: :atoms))
    end

    test "keys: :atoms casts keys inside an ndjson list too" do
      assert {:ok, %Response{body: [%{a: 1}, %{b: 2}]}} =
               Response.decode(
                 response(~s({"a":1}\n{"b":2}\n)),
                 request(format: :ndjson, keys: :atoms)
               )
    end

    test "keys: :atoms! succeeds for a key that already exists as an atom" do
      _existing = String.to_atom("response_test_existing_key")

      assert {:ok, %Response{body: %{response_test_existing_key: 1}}} =
               Response.decode(
                 response(~s({"response_test_existing_key":1})),
                 request(keys: :atoms!)
               )
    end

    test "keys: a function of arity 1 is applied to every key" do
      assert {:ok, %Response{body: %{"A" => %{"B" => [%{"C" => 1}]}}}} =
               Response.decode(
                 response(~s({"a":{"b":[{"c":1}]}})),
                 request(keys: &String.upcase/1)
               )
    end

    test "keys: :atoms! wraps the ArgumentError for an unknown atom" do
      assert {:error, %Error{reason: {:decode_failed, %ArgumentError{}}} = error} =
               Response.decode(
                 response(~s({"response_test_definitely_unknown_key":1})),
                 request(keys: :atoms!)
               )

      assert Exception.message(error) =~ "decoding the response body failed"
    end

    test "a decoder receives the whole decoded body, its own options and :key_fn" do
      decoder = fn body, opts ->
        %{"seen" => body, "key" => opts[:key_fn].("k"), "mapping" => opts[:mapping]}
      end

      assert {:ok, %Response{body: decoded}} =
               Response.decode(
                 response(~s({"a":1})),
                 request(keys: :atoms, decoder: {decoder, mapping: :some_mapping})
               )

      assert decoded == %{"seen" => %{"a" => 1}, "key" => :k, "mapping" => :some_mapping}
    end

    test "the decoder owns the body — its output is not key-cast afterwards" do
      decoder = fn _body, _opts -> %{"left" => "alone"} end

      assert {:ok, %Response{body: %{"left" => "alone"}}} =
               Response.decode(response(~s({"a":1})), request(keys: :atoms, decoder: decoder))
    end

    test "a decoder also gets the resolved context in opts" do
      context = Context.new(endpoint: "http://x:9200")
      decoder = fn _body, opts -> opts[:context] end

      assert {:ok, %Response{body: ^context}} =
               Response.decode(response(~s({"a":1})), request(context: context, decoder: decoder))
    end

    test "a JSON null body skips the decoder entirely" do
      decoder = fn _body, _opts -> raise "never called" end

      assert {:ok, %Response{body: nil}} =
               Response.decode(response("null"), request(keys: :atoms, decoder: decoder))
    end

    test "an empty body skips the decoder entirely" do
      decoder = fn _body, _opts -> raise "never called" end

      assert {:ok, %Response{body: ""}} =
               Response.decode(response(""), request(decoder: decoder))

      assert {:ok, %Response{body: nil}} =
               Response.decode(response(nil), request(decoder: decoder))
    end

    test "an ndjson body is decoded entry by entry, not as one list" do
      decoder = fn entry, opts -> Map.put(entry, opts[:key_fn].("line"), true) end

      assert {:ok, %Response{body: [first, second]}} =
               Response.decode(
                 response(~s({"a":1}\n{"b":2}\n)),
                 request(format: :ndjson, keys: :atoms, decoder: decoder)
               )

      # The decoder owns the keys of each entry, exactly as for a JSON body: it
      # was handed :key_fn and only applied it to the key it added itself.
      assert first == %{:line => true, "a" => 1}
      assert second == %{:line => true, "b" => 2}
    end

    test "a raising decoder on an ndjson body is wrapped too" do
      decoder = fn _entry, _opts -> raise "boom" end

      assert {:error, %Error{reason: {:decode_failed, %RuntimeError{message: "boom"}}}} =
               Response.decode(
                 response(~s({"a":1}\n)),
                 request(format: :ndjson, decoder: decoder)
               )
    end

    test "a raising decoder is wrapped rather than crashing the caller" do
      decoder = fn _body, _opts -> raise "boom" end

      assert {:error, %Error{reason: {:decode_failed, %RuntimeError{message: "boom"}}}} =
               Response.decode(response(~s({"a":1})), request(decoder: decoder))
    end

    test "the second pass is skipped for a raw body" do
      assert Response.decode(response(~s({"a":1})), request(format: :raw, keys: :atoms)) ==
               {:ok, response(~s({"a":1}))}
    end

    test "the second pass is skipped for an empty body" do
      assert Response.decode(response(""), request(keys: :atoms)) == {:ok, response("")}
    end
  end
end
