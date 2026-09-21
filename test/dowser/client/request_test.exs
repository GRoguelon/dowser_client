defmodule Dowser.Client.RequestTestEncoder do
  @moduledoc false

  def encode(source, opts), do: Map.put(source, "index", opts[:index])
end

defmodule Dowser.Client.RequestTestDecoder do
  @moduledoc false

  def decode(body, opts), do: Map.put(body, "mapping", opts[:mapping])
end

defmodule Dowser.Client.RequestTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.Context
  alias Dowser.Client.Error
  alias Dowser.Client.JSON.Error, as: JSONError
  alias Dowser.Client.Request

  defp context(opts \\ []) do
    Context.new(Keyword.merge([endpoint: "http://es:9200"], opts))
  end

  describe "url" do
    test "joins endpoint and path" do
      assert {:ok, request} = Request.new(context(), :get, "/_search", nil, [])
      assert request.url == "http://es:9200/_search"
    end

    test "appends query params (lists comma-joined, booleans stringified)" do
      assert {:ok, request} =
               Request.new(context(), :get, "/_search", nil,
                 params: [_source: ["a", "b"], refresh: true]
               )

      assert request.url == "http://es:9200/_search?_source=a%2Cb&refresh=true"
    end

    test "uses an absolute path verbatim" do
      assert {:ok, request} = Request.new(context(), :get, "http://other:9200/x", nil, [])
      assert request.url == "http://other:9200/x"
    end

    test "a relative path without a leading slash still gets one" do
      assert {:ok, request} = Request.new(context(), :get, "_search", nil, [])
      assert request.url == "http://es:9200/_search"
    end

    test "a nil or empty path is dropped, leaving just the endpoint" do
      assert {:ok, request} = Request.new(context(), :get, nil, nil, [])
      assert request.url == "http://es:9200"

      assert {:ok, request} = Request.new(context(), :get, "", nil, [])
      assert request.url == "http://es:9200"
    end
  end

  describe "headers" do
    setup do
      Application.put_env(:dowser_client, :http_opts, headers: %{"x-global" => "g"})
      on_exit(fn -> Application.delete_env(:dowser_client, :http_opts) end)
    end

    test "merges global, context (auth + http_opts headers) and request headers" do
      context = context(auth: {:bearer, "tok"}, http_opts: [headers: [{"x-context", "c"}]])

      assert {:ok, request} =
               Request.new(context, :post, "/", nil, http_opts: [headers: [{"x-request", "r"}]])

      headers = Map.new(request.headers)
      assert headers["x-global"] == "g"
      assert headers["x-context"] == "c"
      assert headers["x-request"] == "r"
      assert headers["authorization"] == "Bearer tok"
      assert headers["content-type"] == "application/json"
    end

    test "request headers win over context headers on name clash" do
      context = context(http_opts: [headers: [{"x-dup", "context"}]])

      assert {:ok, request} =
               Request.new(context, :get, "/", nil, http_opts: [headers: [{"x-dup", "request"}]])

      assert Map.new(request.headers)["x-dup"] == "request"
    end

    test "accepts headers as a map or a list of tuples at any tier" do
      context = context(http_opts: [headers: %{"x-context" => "c"}])

      assert {:ok, request} =
               Request.new(context, :get, "/", nil, http_opts: [headers: [{"x-request", "r"}]])

      headers = Map.new(request.headers)
      assert headers["x-context"] == "c"
      assert headers["x-request"] == "r"
    end

    test "auth: {:api_key, value} sends the value as given" do
      assert authorization(auth: {:api_key, "key-1"}) == "ApiKey key-1"
    end

    test "auth: {:api_key, id, api_key} base64-encodes the pair" do
      assert authorization(auth: {:api_key, "id-1", "key-1"}) ==
               "ApiKey " <> Base.encode64("id-1:key-1")
    end

    test "auth: {:basic, value} sends the value as given, already encoded" do
      assert authorization(auth: {:basic, "dXNlcjpwYXNz"}) == "Basic dXNlcjpwYXNz"
    end

    test "auth: {:basic, username, password} base64-encodes the pair" do
      assert authorization(auth: {:basic, "user", "changeme"}) ==
               "Basic " <> Base.encode64("user:changeme")
    end

    test "auth: {:bearer, token} sends a Bearer token" do
      assert authorization(auth: {:bearer, "tok-1"}) == "Bearer tok-1"
    end

    test "auth: {:header, name, value} sets an arbitrary header" do
      assert {:ok, request} =
               Request.new(context(auth: {:header, "x-auth", "s3cr3t"}), :get, "/", nil, [])

      assert Map.new(request.headers)["x-auth"] == "s3cr3t"
    end

    test "an auth shape that isn't recognized is a clear error, not a crash" do
      for auth <- [
            {:basic, "user", :changeme},
            {:api_key, 1},
            {:token, "t"},
            {:bearer, "a", "b"},
            "raw-secret"
          ] do
        assert {:error, %Error{reason: {:invalid_auth, ^auth}} = error} =
                 Request.new(context(auth: auth), :get, "/", nil, [])

        assert Exception.message(error) =~ "invalid :auth"
      end
    end

    defp authorization(context_opts) do
      assert {:ok, request} = Request.new(context(context_opts), :get, "/", nil, [])

      Map.new(request.headers)["authorization"]
    end
  end

  describe "format / body encoding" do
    test "json encodes the body and sets content-type" do
      assert {:ok, request} = Request.new(context(), :post, "/", %{"a" => 1}, [])
      assert IO.iodata_to_binary(request.body) == ~s({"a":1})
      assert Map.new(request.headers)["content-type"] == "application/json"
    end

    test "ndjson encodes a list and sets the ndjson content-type" do
      assert {:ok, request} =
               Request.new(context(), :post, "/_bulk", [%{"a" => 1}, %{"b" => 2}],
                 format: :ndjson
               )

      assert IO.iodata_to_binary(request.body) == ~s({"a":1}\n{"b":2}\n)
      assert Map.new(request.headers)["content-type"] == "application/x-ndjson"
    end

    test "raw passes the body through untouched" do
      assert {:ok, request} = Request.new(context(), :post, "/", "already-encoded", format: :raw)
      assert request.body == "already-encoded"
    end

    test "a nil body is never encoded" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, format: :json)
      assert request.body == nil
    end

    test "an invalid format is a generic error" do
      assert {:error, %Error{reason: {:invalid_format, :xml}}} =
               Request.new(context(), :get, "/", nil, format: :xml)
    end

    test "an encoding failure is wrapped in a JSON error" do
      assert {:error, %JSONError{operation: :encode}} =
               Request.new(context(), :post, "/", {:not, :json}, format: :json)
    end

    test "a term with no JSON representation is wrapped in a JSON error, for ndjson too" do
      assert {:error, %JSONError{operation: :encode}} =
               Request.new(context(), :post, "/", [{:not, :json}], format: :ndjson)
    end

    test "a request body is encoded as given when nothing asks for encoding" do
      assert {:ok, request} = Request.new(context(), :post, "/", %{"a" => 1}, [])

      assert IO.iodata_to_binary(request.body) == ~s({"a":1})
    end
  end

  describe "encoder / encode (the request pass)" do
    defp source_encoder do
      fn source, opts -> Map.put(source, "encoded", opts[:index]) end
    end

    test "nothing is encoded unless a request says where the source is" do
      context = context(encoder: fn _source, _opts -> raise "never called" end)

      assert {:ok, request} = Request.new(context, :post, "/_search", %{"q" => 1}, [])

      assert IO.iodata_to_binary(request.body) == ~s({"q":1})
    end

    test "encode: true encodes the whole body" do
      context = context(encoder: {source_encoder(), index: "articles"})

      assert {:ok, request} = Request.new(context, :put, "/_doc/1", %{"t" => "x"}, encode: true)

      assert IO.iodata_to_binary(request.body) == ~s({"encoded":"articles","t":"x"})
    end

    test "encode: a path encodes only the source under it" do
      context = context(encoder: source_encoder())
      body = %{"doc" => %{"t" => "x"}, "doc_as_upsert" => true}

      assert {:ok, request} =
               Request.new(context, :post, "/_update/1", body,
                 encoder: {source_encoder(), index: "articles"},
                 encode: ["doc"]
               )

      assert IO.iodata_to_binary(request.body) ==
               ~s({"doc":{"encoded":"articles","t":"x"},"doc_as_upsert":true})
    end

    test "encode: a list of paths encodes each of them" do
      context = context(encoder: source_encoder())
      body = %{"doc" => %{"t" => "x"}, "upsert" => %{"t" => "y"}}

      assert {:ok, request} =
               Request.new(context, :post, "/_update/1", body, encode: [["doc"], ["upsert"]])

      assert IO.iodata_to_binary(request.body) ==
               ~s({"doc":{"encoded":null,"t":"x"},"upsert":{"encoded":null,"t":"y"}})
    end

    test "encode: false is the default, and skips a configured encoder" do
      context = context(encoder: source_encoder())

      assert {:ok, request} = Request.new(context, :post, "/", %{"q" => 1}, encode: false)

      assert IO.iodata_to_binary(request.body) == ~s({"q":1})
    end

    test "a module encoder is accepted, with or without its options" do
      assert {:ok, request} =
               Request.new(context(), :put, "/_doc/1", %{"t" => "x"},
                 encoder: {Dowser.Client.RequestTestEncoder, index: "articles"},
                 encode: true
               )

      assert IO.iodata_to_binary(request.body) == ~s({"index":"articles","t":"x"})

      assert {:ok, request} =
               Request.new(context(), :put, "/_doc/1", %{"t" => "x"},
                 encoder: Dowser.Client.RequestTestEncoder,
                 encode: true
               )

      assert IO.iodata_to_binary(request.body) == ~s({"index":null,"t":"x"})
    end

    test "a request-level encoder overrides the context's" do
      context = context(encoder: fn _source, _opts -> raise "never called" end)

      assert {:ok, request} =
               Request.new(context, :put, "/_doc/1", %{"t" => "x"},
                 encoder: source_encoder(),
                 encode: true
               )

      assert IO.iodata_to_binary(request.body) == ~s({"encoded":null,"t":"x"})
    end

    test "the encoder carries its own options, and always receives the context" do
      encoder = fn source, opts ->
        Map.merge(source, %{
          "index" => opts[:index],
          "endpoint" => opts[:context].endpoint
        })
      end

      context = context(encoder: {encoder, index: "from-context"})

      assert {:ok, request} = Request.new(context, :put, "/_doc/1", %{}, encode: true)

      assert {:ok, decoded} = JSON.decode(IO.iodata_to_binary(request.body))

      assert decoded == %{"endpoint" => "http://es:9200", "index" => "from-context"}
    end

    # The whole option is replaced, options included — there is no per-key
    # merging across tiers, so a request naming an encoder names its options too.
    test "a request-level encoder replaces the context's, options and all" do
      context = context(encoder: {source_encoder(), index: "from-context"})

      assert {:ok, request} =
               Request.new(context, :put, "/_doc/1", %{"t" => "x"},
                 encoder: {source_encoder(), index: "from-request"},
                 encode: true
               )

      assert IO.iodata_to_binary(request.body) == ~s({"encoded":"from-request","t":"x"})
    end

    test "the encoder resolves request -> context -> app env" do
      Application.put_env(:dowser_client, :encoder, {source_encoder(), index: "from-app-env"})
      on_exit(fn -> Application.delete_env(:dowser_client, :encoder) end)

      assert {:ok, request} = Request.new(context(), :put, "/_doc/1", %{"t" => "x"}, encode: true)
      assert IO.iodata_to_binary(request.body) == ~s({"encoded":"from-app-env","t":"x"})

      context = context(encoder: {source_encoder(), index: "from-context"})

      assert {:ok, request} = Request.new(context, :put, "/_doc/1", %{"t" => "x"}, encode: true)
      assert IO.iodata_to_binary(request.body) == ~s({"encoded":"from-context","t":"x"})

      assert {:ok, request} =
               Request.new(context, :put, "/_doc/1", %{"t" => "x"},
                 encoder: {source_encoder(), index: "from-request"},
                 encode: true
               )

      assert IO.iodata_to_binary(request.body) == ~s({"encoded":"from-request","t":"x"})
    end

    # An ndjson payload is cast per entry, so the encoder sees one line at a
    # time and can tell an action line from a document itself.
    test "an ndjson body is encoded entry by entry" do
      encoder = fn
        %{"index" => _action} = action, _opts -> action
        document, opts -> Map.put(document, "encoded", opts[:index])
      end

      context = context(encoder: {encoder, index: "articles"})
      entries = [%{"index" => %{"_id" => "1"}}, %{"t" => "x"}]

      assert {:ok, request} =
               Request.new(context, :post, "/_bulk", entries, format: :ndjson, encode: true)

      assert IO.iodata_to_binary(request.body) ==
               ~s({"index":{"_id":"1"}}\n{"encoded":"articles","t":"x"}\n)
    end

    test "an ndjson path applies within each entry, skipping lines without it" do
      context = context(encoder: source_encoder())
      entries = [%{"update" => %{"_id" => "1"}}, %{"doc" => %{"t" => "x"}}]

      assert {:ok, request} =
               Request.new(context, :post, "/_bulk", entries,
                 format: :ndjson,
                 encode: ["doc"]
               )

      assert IO.iodata_to_binary(request.body) ==
               ~s({"update":{"_id":"1"}}\n{"doc":{"encoded":null,"t":"x"}}\n)
    end

    test "an ndjson body that isn't a list is an error, not a crash" do
      assert {:error, %Error{reason: {:invalid_ndjson, %{"a" => 1}}}} =
               Request.new(context(), :post, "/_bulk", %{"a" => 1}, format: :ndjson)
    end

    test "a raw body skips the encoder entirely" do
      context = context(encoder: fn _source, _opts -> raise "never called" end)

      assert {:ok, request} =
               Request.new(context, :post, "/", "already-encoded", format: :raw, encode: true)

      assert request.body == "already-encoded"
    end

    test "a nil body skips the encoder entirely" do
      context = context(encoder: fn _source, _opts -> raise "never called" end)

      assert {:ok, request} = Request.new(context, :get, "/", nil, encode: true)

      assert request.body == nil
    end

    test "a raising encoder is wrapped rather than crashing the caller" do
      context = context(encoder: fn _source, _opts -> raise "boom" end)

      assert {:error, %Error{reason: {:encode_failed, %RuntimeError{message: "boom"}}} = error} =
               Request.new(context, :put, "/_doc/1", %{"t" => "x"}, encode: true)

      assert Exception.message(error) =~ "encoding the request body failed"
    end

    test "an invalid :encoder is a generic error" do
      assert {:error, %Error{reason: {:invalid_encoder, :nope}} = error} =
               Request.new(context(), :put, "/", %{}, encoder: :nope, encode: true)

      assert Exception.message(error) =~ "or a module exporting encode/2"
    end

    test "an invalid :encode is a generic error" do
      assert {:error, %Error{reason: {:invalid_encode, :root}} = error} =
               Request.new(context(), :put, "/", %{}, encode: :root)

      assert Exception.message(error) =~ "expected true, false, a path"
    end
  end

  # `%Request{}` has no `:req_format` field (it's resolved and used
  # internally to encode the body, then discarded) — so these tests observe
  # req_format's effect (content-type header, encoded body shape) rather
  # than reading it back off the struct. `:resp_format` IS a real field.
  describe "req_format / resp_format" do
    test ":format sets both directions" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, format: :ndjson)
      assert request.resp_format == :ndjson
      assert Map.new(request.headers)["content-type"] == "application/x-ndjson"
    end

    test "both default to :json" do
      assert {:ok, request} = Request.new(context(), :post, "/", %{"a" => 1}, [])
      assert request.resp_format == :json
      assert Map.new(request.headers)["content-type"] == "application/json"
    end

    test "the two directions are independent" do
      assert {:ok, request} =
               Request.new(context(), :post, "/", %{"a" => 1},
                 req_format: :json,
                 resp_format: :raw
               )

      assert request.resp_format == :raw
      assert IO.iodata_to_binary(request.body) == ~s({"a":1})
      headers = Map.new(request.headers)
      assert headers["content-type"] == "application/json"
      refute Map.has_key?(headers, "accept")
    end

    test "a missing direction falls back to :json" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, resp_format: :raw)
      assert request.resp_format == :raw
      assert Map.new(request.headers)["content-type"] == "application/json"
    end

    test ":format is mutually exclusive with :req_format and :resp_format" do
      assert {:error, %Error{reason: :conflicting_formats}} =
               Request.new(context(), :get, "/", nil, format: :json, req_format: :raw)

      assert {:error, %Error{reason: :conflicting_formats}} =
               Request.new(context(), :get, "/", nil, format: :json, resp_format: :raw)
    end

    test "an invalid direction is a generic error" do
      assert {:error, %Error{reason: {:invalid_format, :xml}}} =
               Request.new(context(), :get, "/", nil, req_format: :xml)
    end
  end

  describe "adapter and profile selection" do
    # An option that named *where* a request goes must fail rather than be
    # ignored: `config: :logs` silently resolving to the default context would
    # query the wrong cluster.
    test "the removed :http_adapter and :config options are clear errors" do
      assert {:error, %Error{reason: {:removed_option, :http_adapter}} = error} =
               Request.new(context(), :get, "/", nil, http_adapter: SomeAdapter)

      assert Exception.message(error) =~ ":http_adapter was removed in 0.2.0"
      assert Exception.message(error) =~ "UPGRADE_GUIDE_0_2.md"

      assert {:error, %Error{reason: {:removed_option, :config}} = error} =
               Request.new(context(), :get, "/", nil, config: :logs)

      assert Exception.message(error) =~ "the option is now :context"
    end

    # The rest only shaped a body, so the request proceeds — but it says so,
    # rather than doing nothing the caller asked for in silence.
    test "the other removed options warn and are ignored" do
      for {option, value, hint} <- [
            {:codec_adapter, SomeCodec, "use :decoder"},
            {:codec_opts, [mapping: 1], "carries its own options"},
            {:json_adapter, SomeJSON, "built-in JSON module"},
            {:json_opts, [pretty: true], "built-in JSON module"}
          ] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, _request} = Request.new(context(), :get, "/", nil, [{option, value}])
          end)

        assert log =~ "#{inspect(option)} was removed in 0.2.0 and is ignored"
        assert log =~ hint
        assert log =~ "UPGRADE_GUIDE_0_2.md"
      end
    end

    test "a request with none of them logs nothing" do
      assert ExUnit.CaptureLog.capture_log(fn ->
               assert {:ok, _request} = Request.new(context(), :get, "/", nil, keys: :atoms)
             end) == ""
    end

    test "defaults to the :dowser_client profile and no second pass" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, [])
      assert request.http_opts[:profile] == :dowser_client
      assert request.key_fn == nil
      assert request.decoder == nil
    end

    # Regression: defaults used to be frozen at compile time via
    # `Application.compile_env/3` on the struct. They're now resolved at
    # request time via `Application.get_env/3`, so a context without an
    # explicit value picks up a *runtime* app-env override.
    test "a runtime app-env default is picked up when neither opts nor context set one" do
      Application.put_env(:dowser_client, :keys, :atoms)
      Application.put_env(:dowser_client, :profile, :from_app_env)

      on_exit(fn ->
        Enum.each([:keys, :profile], &Application.delete_env(:dowser_client, &1))
      end)

      assert {:ok, request} = Request.new(context(), :get, "/", nil, [])
      assert request.key_fn.("a") == :a
      assert request.http_opts[:profile] == :from_app_env
    end

    test "the profile resolves request -> context -> app env -> default" do
      Application.put_env(:dowser_client, :profile, :from_app_env)
      on_exit(fn -> Application.delete_env(:dowser_client, :profile) end)

      assert {:ok, request} = Request.new(context(), :get, "/", nil, [])
      assert request.http_opts[:profile] == :from_app_env

      assert {:ok, request} = Request.new(context(profile: :from_config), :get, "/", nil, [])
      assert request.http_opts[:profile] == :from_config

      assert {:ok, request} =
               Request.new(context(profile: :from_config), :get, "/", nil,
                 http_opts: [profile: :from_request]
               )

      assert request.http_opts[:profile] == :from_request
    end

    test ":profile_opts merge global -> context -> request" do
      Application.put_env(:dowser_client, :profile_opts, max_sessions: 1, cookies: :enabled)
      on_exit(fn -> Application.delete_env(:dowser_client, :profile_opts) end)

      context = context(profile_opts: [max_sessions: 2, keep_alive_timeout: 1_000])

      assert {:ok, request} =
               Request.new(context, :get, "/", nil, http_opts: [profile_opts: [max_sessions: 3]])

      assert Enum.sort(request.http_opts[:profile_opts]) ==
               Enum.sort(cookies: :enabled, max_sessions: 3, keep_alive_timeout: 1_000)
    end

    test ":ssl merges per key across global -> context -> request" do
      Application.put_env(:dowser_client, :http_opts, ssl: [cacertfile: "/ca.pem", depth: 1])
      on_exit(fn -> Application.delete_env(:dowser_client, :http_opts) end)

      context = context(http_opts: [ssl: [depth: 5]])

      assert {:ok, request} =
               Request.new(context, :get, "/", nil, http_opts: [ssl: [verify_hostname: false]])

      assert Enum.sort(request.http_opts[:ssl]) ==
               Enum.sort(cacertfile: "/ca.pem", depth: 5, verify_hostname: false)
    end

    test "opts[:http_opts] becomes the transport options (minus :headers)" do
      assert {:ok, request} =
               Request.new(context(), :get, "/", nil,
                 http_opts: [timeout: 5000, headers: [{"x", "y"}]]
               )

      assert Keyword.drop(request.http_opts, [:profile, :profile_opts]) == [timeout: 5000]
    end

    test "http_opts merge global -> context -> request" do
      Application.put_env(:dowser_client, :http_opts, connect_timeout: 1)
      on_exit(fn -> Application.delete_env(:dowser_client, :http_opts) end)

      assert {:ok, request} =
               Request.new(context(http_opts: [timeout: 5000]), :get, "/", nil,
                 http_opts: [timeout: 9999]
               )

      assert Keyword.drop(request.http_opts, [:profile, :profile_opts]) == [
               connect_timeout: 1,
               timeout: 9999
             ]
    end
  end

  describe "retry" do
    test "defaults when :retry is absent" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, [])
      assert request.retry[:max_attempts] == 3
    end

    test "a partial keyword list overrides only the given keys" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, retry: [max_attempts: 5])

      assert request.retry[:max_attempts] == 5
      assert request.retry[:base_delay_ms] == 200
    end

    test "retry: false disables retries" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, retry: false)
      assert request.retry[:max_attempts] == 1
    end

    test "an invalid :retry value is a generic error" do
      assert {:error, %Error{reason: {:invalid_retry, :bogus}}} =
               Request.new(context(), :get, "/", nil, retry: :bogus)
    end
  end

  describe "keys / decoder (the second pass)" do
    test "neither set means no second pass at all" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, [])

      assert request.key_fn == nil
      assert request.decoder == nil
    end

    test "keys: :strings casts nothing, so it stays a no-op pass" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, keys: :strings)

      assert request.key_fn == nil
    end

    test "keys accepts :atoms, :atoms! and a function" do
      assert {:ok, request} = Request.new(context(), :get, "/", nil, keys: :atoms)
      assert request.key_fn.("a") == :a

      assert {:ok, request} = Request.new(context(), :get, "/", nil, keys: :atoms!)
      assert request.key_fn == (&String.to_existing_atom/1)

      assert {:ok, request} = Request.new(context(), :get, "/", nil, keys: &String.upcase/1)
      assert request.key_fn.("a") == "A"
    end

    test "a decoder of arity 2 resolves with just the context in its options" do
      decoder = fn body, _opts -> body end
      context = context()

      assert {:ok, request} = Request.new(context, :get, "/", nil, decoder: decoder)

      assert request.decoder == {decoder, context: context}
    end

    test "a decoder carries its own options, and always receives the context" do
      decoder = fn body, _opts -> body end
      context = context()

      assert {:ok, request} =
               Request.new(context, :get, "/", nil, decoder: {decoder, mapping: :m})

      assert {^decoder, opts} = request.decoder
      assert opts[:mapping] == :m
      assert opts[:context] == context
    end

    test "a module decoder is accepted, with or without its options" do
      assert {:ok, request} =
               Request.new(context(), :get, "/", nil,
                 decoder: {Dowser.Client.RequestTestDecoder, mapping: :m}
               )

      assert {fun, opts} = request.decoder
      assert is_function(fun, 2)
      assert opts[:mapping] == :m

      assert {:ok, request} =
               Request.new(context(), :get, "/", nil, decoder: Dowser.Client.RequestTestDecoder)

      assert {_fun, opts} = request.decoder
      refute Keyword.has_key?(opts, :mapping)
    end

    test "opts fall back to the context's values" do
      decoder = fn body, _opts -> body end
      context = context(keys: :atoms, decoder: {decoder, mapping: :from_context})

      assert {:ok, request} = Request.new(context, :get, "/", nil, [])

      assert request.key_fn.("a") == :a
      assert {^decoder, opts} = request.decoder
      assert opts[:mapping] == :from_context
      assert opts[:context] == context
    end

    test "opts override the context's values" do
      assert {:ok, request} = Request.new(context(keys: :atoms), :get, "/", nil, keys: :strings)

      assert request.key_fn == nil
    end

    # The whole option is replaced, options included — there is no per-key
    # merging across tiers.
    test "a request-level decoder replaces the context's, options and all" do
      decoder = fn body, _opts -> body end
      context = context(decoder: {decoder, mapping: :from_context})

      assert {:ok, request} =
               Request.new(context, :get, "/", nil, decoder: {decoder, mapping: :from_request})

      assert {_fun, opts} = request.decoder
      assert opts[:mapping] == :from_request
    end

    test "the decoder resolves request -> context -> app env" do
      decoder = fn body, _opts -> body end

      Application.put_env(:dowser_client, :decoder, {decoder, mapping: :from_app_env})
      on_exit(fn -> Application.delete_env(:dowser_client, :decoder) end)

      assert {:ok, request} = Request.new(context(), :get, "/", nil, [])
      assert {_fun, opts} = request.decoder
      assert opts[:mapping] == :from_app_env

      context = context(decoder: {decoder, mapping: :from_context})

      assert {:ok, request} = Request.new(context, :get, "/", nil, [])
      assert {_fun, opts} = request.decoder
      assert opts[:mapping] == :from_context

      assert {:ok, request} =
               Request.new(context, :get, "/", nil, decoder: {decoder, mapping: :from_request})

      assert {_fun, opts} = request.decoder
      assert opts[:mapping] == :from_request
    end

    test "an invalid :decoder is a generic error" do
      assert {:error, %Error{reason: {:invalid_decoder, :nope}} = error} =
               Request.new(context(), :get, "/", nil, decoder: :nope)

      assert Exception.message(error) =~ "or a module exporting decode/2"
    end

    test "an invalid :keys value is a generic error, with a suggestion for a typo" do
      assert {:error, %Error{reason: {:invalid_keys, :atom}} = error} =
               Request.new(context(), :get, "/", nil, keys: :atom)

      assert Exception.message(error) =~ "did you mean :atoms?"
    end

    test "a :decoder of the wrong arity is rejected" do
      assert {:error, %Error{reason: {:invalid_decoder, _fun}} = error} =
               Request.new(context(), :get, "/", nil, decoder: fn body -> body end)

      assert Exception.message(error) =~ "expected a function of arity 2"
    end
  end
end
