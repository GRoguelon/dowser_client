defmodule Dowser.Client.RequestRaisingJSONAdapter do
  @moduledoc false
  @behaviour Dowser.Client.JSON.Adapter

  @impl true
  def encode(_term, _opts), do: raise("adapter blew up")

  @impl true
  def decode(binary, opts), do: Dowser.Client.JSON.Native.decode(binary, opts)
end

defmodule Dowser.Client.RequestTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.Config
  alias Dowser.Client.Error
  alias Dowser.Client.FakeCodec
  alias Dowser.Client.JSON.Error, as: JSONError
  alias Dowser.Client.Request

  defp config(opts \\ []) do
    Config.new(Keyword.merge([endpoint: "http://es:9200"], opts))
  end

  describe "url" do
    test "joins endpoint and path" do
      assert {:ok, request} = Request.new(config(), :get, "/_search", nil, [])
      assert request.url == "http://es:9200/_search"
    end

    test "appends query params (lists comma-joined, booleans stringified)" do
      assert {:ok, request} =
               Request.new(config(), :get, "/_search", nil,
                 params: [_source: ["a", "b"], refresh: true]
               )

      assert request.url == "http://es:9200/_search?_source=a%2Cb&refresh=true"
    end

    test "uses an absolute path verbatim" do
      assert {:ok, request} = Request.new(config(), :get, "http://other:9200/x", nil, [])
      assert request.url == "http://other:9200/x"
    end

    test "a relative path without a leading slash still gets one" do
      assert {:ok, request} = Request.new(config(), :get, "_search", nil, [])
      assert request.url == "http://es:9200/_search"
    end

    test "a nil or empty path is dropped, leaving just the endpoint" do
      assert {:ok, request} = Request.new(config(), :get, nil, nil, [])
      assert request.url == "http://es:9200"

      assert {:ok, request} = Request.new(config(), :get, "", nil, [])
      assert request.url == "http://es:9200"
    end
  end

  describe "headers" do
    setup do
      Application.put_env(:dowser_client, :http_opts, headers: %{"x-global" => "g"})
      on_exit(fn -> Application.delete_env(:dowser_client, :http_opts) end)
    end

    test "merges global, config (auth + http_opts headers) and request headers" do
      config = config(auth: {:bearer, "tok"}, http_opts: [headers: [{"x-config", "c"}]])

      assert {:ok, request} =
               Request.new(config, :post, "/", nil, http_opts: [headers: [{"x-request", "r"}]])

      headers = Map.new(request.headers)
      assert headers["x-global"] == "g"
      assert headers["x-config"] == "c"
      assert headers["x-request"] == "r"
      assert headers["authorization"] == "Bearer tok"
      assert headers["content-type"] == "application/json"
    end

    test "request headers win over config headers on name clash" do
      config = config(http_opts: [headers: [{"x-dup", "config"}]])

      assert {:ok, request} =
               Request.new(config, :get, "/", nil, http_opts: [headers: [{"x-dup", "request"}]])

      assert Map.new(request.headers)["x-dup"] == "request"
    end

    test "accepts headers as a map or a list of tuples at any tier" do
      config = config(http_opts: [headers: %{"x-config" => "c"}])

      assert {:ok, request} =
               Request.new(config, :get, "/", nil, http_opts: [headers: [{"x-request", "r"}]])

      headers = Map.new(request.headers)
      assert headers["x-config"] == "c"
      assert headers["x-request"] == "r"
    end

    test "auth: {:api_key, key} sets an ApiKey authorization header" do
      assert {:ok, request} = Request.new(config(auth: {:api_key, "key-1"}), :get, "/", nil, [])
      assert Map.new(request.headers)["authorization"] == "ApiKey key-1"
    end

    test "auth: {:header, name, value} sets an arbitrary header" do
      assert {:ok, request} =
               Request.new(config(auth: {:header, "x-auth", "s3cr3t"}), :get, "/", nil, [])

      assert Map.new(request.headers)["x-auth"] == "s3cr3t"
    end
  end

  describe "format / body encoding" do
    test "json encodes the body and sets content-type" do
      assert {:ok, request} = Request.new(config(), :post, "/", %{"a" => 1}, [])
      assert IO.iodata_to_binary(request.body) == ~s({"a":1})
      assert Map.new(request.headers)["content-type"] == "application/json"
    end

    test "ndjson encodes a list and sets the ndjson content-type" do
      assert {:ok, request} =
               Request.new(config(), :post, "/_bulk", [%{"a" => 1}, %{"b" => 2}], format: :ndjson)

      assert IO.iodata_to_binary(request.body) == ~s({"a":1}\n{"b":2}\n)
      assert Map.new(request.headers)["content-type"] == "application/x-ndjson"
    end

    test "raw passes the body through untouched" do
      assert {:ok, request} = Request.new(config(), :post, "/", "already-encoded", format: :raw)
      assert request.body == "already-encoded"
    end

    test "a nil body is never encoded" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, format: :json)
      assert request.body == nil
    end

    test "an invalid format is a generic error" do
      assert {:error, %Error{reason: {:invalid_format, :xml}}} =
               Request.new(config(), :get, "/", nil, format: :xml)
    end

    test "an encoding failure is wrapped in a JSON error" do
      assert {:error, %JSONError{operation: :encode}} =
               Request.new(config(), :post, "/", {:not, :json}, format: :json)
    end

    test "a raised (not returned) exception from json_adapter.encode/2 is wrapped in a JSON error" do
      assert {:error,
              %JSONError{operation: :encode, reason: %RuntimeError{message: "adapter blew up"}}} =
               Request.new(config(), :post, "/", %{"a" => 1},
                 json_adapter: Dowser.Client.RequestRaisingJSONAdapter
               )
    end

    test "a raised (not returned) exception from the adapter is wrapped for ndjson too" do
      assert {:error,
              %JSONError{operation: :encode, reason: %RuntimeError{message: "adapter blew up"}}} =
               Request.new(config(), :post, "/", [%{"a" => 1}],
                 format: :ndjson,
                 json_adapter: Dowser.Client.RequestRaisingJSONAdapter
               )
    end

    test "a configured codec_adapter casts the body's values before encoding" do
      fun = fn %{"a" => a}, _opts -> %{"a" => a * 10} end

      assert {:ok, request} =
               Request.new(config(), :post, "/", %{"a" => 1},
                 codec_adapter: FakeCodec,
                 codec_opts: [encode_fun: fun]
               )

      assert IO.iodata_to_binary(request.body) == ~s({"a":10})
    end

    test "codec_adapter.encode/2 receives :config in opts" do
      config = config()

      fun = fn value, opts ->
        send(self(), {:encode_saw, opts[:config]})
        value
      end

      assert {:ok, _request} =
               Request.new(config, :post, "/", %{"a" => 1},
                 codec_adapter: FakeCodec,
                 codec_opts: [encode_fun: fun]
               )

      assert_received {:encode_saw, ^config}
    end

    test "a raised exception from codec_adapter.encode/2 is wrapped in a Codec.Error" do
      config = config(codec_adapter: FakeCodec)

      assert {:error, %Dowser.Client.Codec.Error{codec: FakeCodec, operation: :encode}} =
               Request.new(config, :post, "/", %{"a" => 1},
                 codec_opts: [encode_fun: fn _v, _opts -> raise "boom" end]
               )
    end

    # `codec_adapter: DefaultCodec` is special-cased to skip `encode/2`
    # entirely on the request-encode path (only decode-side key casting
    # applies) — this pins that behavior against accidental removal.
    test "DefaultCodec is not invoked on the request-encode path" do
      assert {:ok, request} =
               Request.new(config(), :post, "/", %{"a" => 1},
                 codec_adapter: Dowser.Client.Codec.Default
               )

      assert IO.iodata_to_binary(request.body) == ~s({"a":1})
    end
  end

  # `%Request{}` has no `:req_format` field (it's resolved and used
  # internally to encode the body, then discarded) — so these tests observe
  # req_format's effect (content-type header, encoded body shape) rather
  # than reading it back off the struct. `:resp_format` IS a real field.
  describe "req_format / resp_format" do
    test ":format sets both directions" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, format: :ndjson)
      assert request.resp_format == :ndjson
      assert Map.new(request.headers)["content-type"] == "application/x-ndjson"
    end

    test "both default to :json" do
      assert {:ok, request} = Request.new(config(), :post, "/", %{"a" => 1}, [])
      assert request.resp_format == :json
      assert Map.new(request.headers)["content-type"] == "application/json"
    end

    test "the two directions are independent" do
      assert {:ok, request} =
               Request.new(config(), :post, "/", %{"a" => 1},
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
      assert {:ok, request} = Request.new(config(), :get, "/", nil, resp_format: :raw)
      assert request.resp_format == :raw
      assert Map.new(request.headers)["content-type"] == "application/json"
    end

    test ":format is mutually exclusive with :req_format and :resp_format" do
      assert {:error, %Error{reason: :conflicting_formats}} =
               Request.new(config(), :get, "/", nil, format: :json, req_format: :raw)

      assert {:error, %Error{reason: :conflicting_formats}} =
               Request.new(config(), :get, "/", nil, format: :json, resp_format: :raw)
    end

    test "an invalid direction is a generic error" do
      assert {:error, %Error{reason: {:invalid_format, :xml}}} =
               Request.new(config(), :get, "/", nil, req_format: :xml)
    end
  end

  describe "adapter selection" do
    test "defaults to the built-in adapters when nothing overrides them" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, [])
      assert request.http_adapter == Dowser.Client.HTTP.Httpc
      assert request.json_adapter == Dowser.Client.JSON.Native
      assert request.codec_adapter == Dowser.Client.Codec.Default
    end

    test "opts[:http_adapter] overrides the config adapter" do
      assert {:ok, request} =
               Request.new(config(), :get, "/", nil, http_adapter: Dowser.Client.HTTP.Req)

      assert request.http_adapter == Dowser.Client.HTTP.Req
    end

    test "opts[:json_adapter] overrides the config adapter" do
      assert {:ok, request} =
               Request.new(config(), :get, "/", nil, json_adapter: Dowser.Client.JSON.Jason)

      assert request.json_adapter == Dowser.Client.JSON.Jason
    end

    test "config's adapter wins over the runtime app-env default" do
      Application.put_env(:dowser_client, :http_adapter, Dowser.Client.HTTP.Req)
      on_exit(fn -> Application.delete_env(:dowser_client, :http_adapter) end)

      assert {:ok, request} =
               Request.new(config(http_adapter: Dowser.Client.HTTP.Hackney), :get, "/", nil, [])

      assert request.http_adapter == Dowser.Client.HTTP.Hackney
    end

    # Regression: adapter defaults used to be frozen at compile time via
    # `Application.compile_env/3` on the struct. They're now resolved at
    # request time via `Application.get_env/3`, so a config without an
    # explicit adapter picks up a *runtime* app-env override.
    test "a runtime app-env default is picked up when neither opts nor config set an adapter" do
      Application.put_env(:dowser_client, :http_adapter, Dowser.Client.HTTP.Req)
      Application.put_env(:dowser_client, :json_adapter, Dowser.Client.JSON.Jason)
      Application.put_env(:dowser_client, :codec_adapter, FakeCodec)

      on_exit(fn ->
        Enum.each(
          [:http_adapter, :json_adapter, :codec_adapter],
          &Application.delete_env(:dowser_client, &1)
        )
      end)

      assert {:ok, request} = Request.new(config(), :get, "/", nil, [])
      assert request.http_adapter == Dowser.Client.HTTP.Req
      assert request.json_adapter == Dowser.Client.JSON.Jason
      assert request.codec_adapter == FakeCodec
    end

    test "opts[:http_opts] becomes the adapter options (minus :headers)" do
      assert {:ok, request} =
               Request.new(config(), :get, "/", nil,
                 http_opts: [recv_timeout: 5000, headers: [{"x", "y"}]]
               )

      assert request.http_opts == [recv_timeout: 5000]
    end

    test "http_opts/json_opts/codec_opts merge global -> config -> request" do
      Application.put_env(:dowser_client, :http_opts, pool_timeout: 1)
      Application.put_env(:dowser_client, :json_opts, escape: :html)
      Application.put_env(:dowser_client, :codec_opts, a: 1)

      on_exit(fn ->
        Enum.each(
          [:http_opts, :json_opts, :codec_opts],
          &Application.delete_env(:dowser_client, &1)
        )
      end)

      config =
        config(http_opts: [recv_timeout: 5000], json_opts: [pretty: true], codec_opts: [b: 2])

      assert {:ok, request} =
               Request.new(config, :get, "/", nil,
                 http_opts: [recv_timeout: 9999],
                 json_opts: [strings: :copy],
                 codec_opts: [c: 3]
               )

      assert request.http_opts == [pool_timeout: 1, recv_timeout: 9999]
      assert request.json_opts == [escape: :html, pretty: true, strings: :copy]
      assert Keyword.take(request.codec_opts, [:a, :b, :c]) == [a: 1, b: 2, c: 3]
    end

    # `:codec_opts` always gets `:key_fn` and `:config` appended by
    # `Dowser.Client.Request.new/5` (see the "keys / codec_adapter" describe
    # below for :key_fn) — this pins the `:config` half of that contract.
    test "codec_opts always carries the resolved :config" do
      config = config()
      assert {:ok, request} = Request.new(config, :get, "/", nil, [])
      assert request.codec_opts[:config] == config
    end
  end

  describe "retry" do
    test "defaults when :retry is absent" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, [])
      assert request.retry[:max_attempts] == 3
    end

    test "a partial keyword list overrides only the given keys" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, retry: [max_attempts: 5])

      assert request.retry[:max_attempts] == 5
      assert request.retry[:base_delay_ms] == 200
    end

    test "retry: false disables retries" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, retry: false)
      assert request.retry[:max_attempts] == 1
    end

    test "an invalid :retry value is a generic error" do
      assert {:error, %Error{reason: {:invalid_retry, :bogus}}} =
               Request.new(config(), :get, "/", nil, retry: :bogus)
    end
  end

  describe "keys / codec_adapter" do
    test "keys defaults to :strings" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, [])
      assert request.codec_opts[:key_fn].("a") == "a"
    end

    test "keys accepts :atoms and :atoms!" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, keys: :atoms)
      assert request.codec_opts[:key_fn].("a") == :a

      assert {:ok, request} = Request.new(config(), :get, "/", nil, keys: :atoms!)
      assert request.codec_opts[:key_fn] == (&String.to_existing_atom/1)
    end

    test "opts[:keys] falls back to the config's :keys" do
      assert {:ok, request} = Request.new(config(keys: :atoms), :get, "/", nil, [])
      assert request.codec_opts[:key_fn].("a") == :a
    end

    test "opts[:keys] overrides the config's :keys" do
      assert {:ok, request} = Request.new(config(keys: :atoms), :get, "/", nil, keys: :strings)
      assert request.codec_opts[:key_fn].("a") == "a"
    end

    test "an invalid :keys value is a generic error" do
      assert {:error, %Error{reason: {:invalid_keys, :bogus_keys}}} =
               Request.new(config(), :get, "/", nil, keys: :bogus_keys)
    end

    test "codec_adapter defaults to DefaultCodec, not nil" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, [])
      assert request.codec_adapter == Dowser.Client.Codec.Default
    end

    test "opts[:codec_adapter] falls back to the config's :codec_adapter" do
      assert {:ok, request} = Request.new(config(codec_adapter: FakeCodec), :get, "/", nil, [])
      assert request.codec_adapter == FakeCodec
    end

    test "opts[:codec_adapter] overrides the config's :codec_adapter" do
      assert {:ok, request} =
               Request.new(config(codec_adapter: FakeCodec), :get, "/", nil,
                 codec_adapter: Dowser.Client.Codec.Default
               )

      assert request.codec_adapter == Dowser.Client.Codec.Default
    end

    test "codec_opts defaults to just the automatically-added :key_fn and :config" do
      assert {:ok, request} = Request.new(config(), :get, "/", nil, [])
      assert Keyword.drop(request.codec_opts, [:key_fn, :config]) == []
    end
  end
end
