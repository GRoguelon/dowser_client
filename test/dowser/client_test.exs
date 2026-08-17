defmodule Dowser.ClientTest do
  use ExUnit.Case, async: false

  alias Dowser.Client
  alias Dowser.Client.Config
  alias Dowser.Client.Error
  alias Dowser.Client.FakeCodec
  alias Dowser.Client.HTTP.Error, as: HTTPError
  alias Dowser.Client.HTTP.FakeAdapter
  alias Dowser.Client.JSON.Error, as: JSONError
  alias Dowser.Client.Response
  alias Dowser.Client.TCPTestServer

  @body ~s({"ok":true})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@body)}\r\n\r\n" <>
              @body

  describe "unwrap/1 (Dowser.unwrap/1)" do
    test "returns the response on success" do
      response = %Response{status: 200}
      assert Dowser.unwrap({:ok, response}) == response
    end

    test "raises the error on failure when it's already an exception" do
      error = %HTTPError{reason: :timeout, method: :get, url: "http://x"}

      assert_raise HTTPError, "HTTP request GET http://x failed: :timeout", fn ->
        Dowser.unwrap({:error, error})
      end
    end

    test "wraps a non-exception error in a Dowser.Client.Error" do
      assert_raise Error, ~r/unwrap\/1 received a non-exception error: :boom/, fn ->
        Dowser.unwrap({:error, :boom})
      end
    end
  end

  describe "request/5 with a config in opts" do
    test "joins the endpoint with the path and injects basic-auth headers" do
      {port, server} = TCPTestServer.start(@response)
      config = Config.new(endpoint: "http://127.0.0.1:#{port}", auth: {:basic, "u", "p"})

      assert {:ok, %Response{status: 200, body: %{"ok" => true}}} =
               Client.request(:get, "/_search", nil,
                 config: config,
                 http_opts: [headers: [{"accept", "application/json"}]]
               )

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_search"
      assert req.headers["authorization"] == "Basic " <> Base.encode64("u:p")
      assert req.headers["accept"] == "application/json"
    end

    test "accepts inline keyword config and sends a raw body" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} =
               Client.request(:post, "/_bulk", "payload", config: config, format: :raw)

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_bulk"
      assert req.body == "payload"
    end

    test "encodes the body as JSON by default and sets content-type" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} =
               Client.request(:post, "/_search", %{"query" => %{"match_all" => %{}}},
                 config: config
               )

      req = Task.await(server)
      assert req.body == ~s({"query":{"match_all":{}}})
      assert req.headers["content-type"] == "application/json"
    end

    test "appends query params to the URL" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "/_search", nil,
                 config: config,
                 params: [routing: "u1", refresh: true]
               )

      assert Task.await(server).path == "/_search?routing=u1&refresh=true"
    end

    test "an absolute URL overrides the config endpoint" do
      {port, server} = TCPTestServer.start(@response)
      config = Config.new(endpoint: "http://elsewhere:9200")

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "http://127.0.0.1:#{port}/", nil, config: config)

      assert Task.await(server).path == "/"
    end
  end

  describe "get/2, post/3, put/3, patch/3, delete/3 convenience wrappers" do
    test "every wrapper's opts (and post/put/patch's body) default when omitted" do
      Application.delete_env(:dowser_client, :configs)

      # No :config given and no :default configured — each should still
      # reach real option resolution (proving the \\ nil / \\ [] defaults
      # are wired through) and fail the same documented way.
      assert {:error, %Error{reason: {:unknown_config, :default}}} = Client.get("/x")
      assert {:error, %Error{reason: {:unknown_config, :default}}} = Client.post("/x")
      assert {:error, %Error{reason: {:unknown_config, :default}}} = Client.put("/x")
      assert {:error, %Error{reason: {:unknown_config, :default}}} = Client.patch("/x")
      assert {:error, %Error{reason: {:unknown_config, :default}}} = Client.delete("/x")
    end

    test "get/2 issues a GET with no body" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.get("/_search", config: config)
      req = Task.await(server)
      assert req.method == "GET"
      assert req.body == ""
    end

    test "post/3 issues a POST with the given body" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.post("/_bulk", %{"a" => 1}, config: config)
      req = Task.await(server)
      assert req.method == "POST"
      assert req.body == ~s({"a":1})
    end

    test "put/3 issues a PUT with the given body" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.put("/doc/1", %{"a" => 1}, config: config)
      assert Task.await(server).method == "PUT"
    end

    test "patch/3 issues a PATCH with the given body" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.patch("/doc/1", %{"a" => 1}, config: config)
      assert Task.await(server).method == "PATCH"
    end

    test "delete/3 issues a DELETE, defaulting its body to nil" do
      {port, server} = TCPTestServer.start(@response)
      config = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.delete("/doc/1", nil, config: config)
      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.body == ""
    end
  end

  describe "request/4 error handling" do
    test "returns {:error, %HTTP.Error{}} when the connection fails" do
      port = TCPTestServer.free_port()
      config = Config.new(endpoint: "http://127.0.0.1:#{port}")

      assert {:error, %HTTPError{} = error} =
               Client.request(:get, "/", nil, config: config, retry: false)

      assert error.method == :get
      assert error.reason != nil
    end

    test "returns {:error, %Error{}} for an unconfigured config atom" do
      Application.delete_env(:dowser_client, :configs)

      assert {:error, %Error{reason: {:unknown_config, :nope}}} =
               Client.request(:get, "/", nil, config: :nope)
    end

    test "returns {:error, %Error{}} when :config is omitted and no :default is configured" do
      Application.delete_env(:dowser_client, :configs)

      assert {:error, %Error{reason: {:unknown_config, :default}}} =
               Client.request(:get, "/", nil, [])
    end

    test "returns {:error, %Error{}} for an invalid :format" do
      assert {:error, %Error{reason: {:invalid_format, :xml}}} =
               Client.request(:get, "/", nil, config: [endpoint: "http://x:9200"], format: :xml)
    end

    test "returns {:error, %Error{}} when :format conflicts with :req_format" do
      assert {:error, %Error{reason: :conflicting_formats}} =
               Client.request(:get, "/", nil,
                 config: [endpoint: "http://x:9200"],
                 format: :json,
                 req_format: :raw
               )
    end

    test "returns {:error, %JSON.Error{}} when the body cannot be encoded" do
      config = [endpoint: "http://x:9200"]

      assert {:error, %JSONError{operation: :encode}} =
               Client.request(:post, "/", {:not, :encodable}, config: config)
    end

    test "returns {:error, %JSON.Error{}} when the response body cannot be decoded" do
      html = "<html>bad</html>"
      response = "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(html)}\r\n\r\n" <> html
      {port, server} = TCPTestServer.start(response)

      assert {:error, %JSONError{operation: :decode}} =
               Client.request(:get, "/", nil, config: [endpoint: "http://127.0.0.1:#{port}"])

      Task.await(server)
    end
  end

  describe "retry" do
    setup do
      start_supervised!(FakeAdapter)
      :ok
    end

    defp fake_config do
      Config.new(endpoint: "http://fake", http_adapter: FakeAdapter)
    end

    test "an unscripted FakeAdapter (no set/1 call) returns {:error, :no_script}" do
      assert {:error, %HTTPError{reason: :no_script}} =
               Client.request(:get, "/", nil, config: fake_config(), retry: false)
    end

    test "retries a transient error until it succeeds" do
      FakeAdapter.set([{:error, :timeout}, {:error, :timeout}, {:ok, %Response{status: 200}}])

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "/", nil, config: fake_config(), retry: [base_delay_ms: 1])

      assert FakeAdapter.calls() == 3
    end

    test "exhausts max_attempts and wraps the last error with the attempt count" do
      FakeAdapter.set([{:error, :timeout}])

      assert {:error, %HTTPError{reason: :timeout, attempts: 3}} =
               Client.request(:get, "/", nil,
                 config: fake_config(),
                 retry: [max_attempts: 3, base_delay_ms: 1]
               )

      assert FakeAdapter.calls() == 3
    end

    test "retry: false performs exactly one attempt" do
      FakeAdapter.set([{:error, :timeout}, {:ok, %Response{status: 200}}])

      assert {:error, %HTTPError{attempts: 1}} =
               Client.request(:get, "/", nil, config: fake_config(), retry: false)

      assert FakeAdapter.calls() == 1
    end

    test "a non-retryable status passes straight through" do
      FakeAdapter.set([{:ok, %Response{status: 404}}])

      assert {:ok, %Response{status: 404}} =
               Client.request(:get, "/", nil, config: fake_config(), format: :raw)

      assert FakeAdapter.calls() == 1
    end

    test "a retryable status is retried until success" do
      FakeAdapter.set([{:ok, %Response{status: 503}}, {:ok, %Response{status: 200}}])

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "/", nil,
                 config: fake_config(),
                 format: :raw,
                 retry: [base_delay_ms: 1]
               )

      assert FakeAdapter.calls() == 2
    end

    test "a non-transient error is not retried" do
      FakeAdapter.set([{:error, :enoent}])

      assert {:error, %HTTPError{reason: :enoent, attempts: 1}} =
               Client.request(:get, "/", nil, config: fake_config())

      assert FakeAdapter.calls() == 1
    end

    # `perform/1`'s `rescue` clause catches anything unexpected raised while
    # running the request/retry pipeline (not just adapter {:error, _}
    # tuples) and turns it into an {:error, exception} instead of crashing
    # the caller.
    test "an unexpected exception raised while running the request is caught and returned" do
      FakeAdapter.set([:not_a_valid_adapter_result])

      assert {:error, %FunctionClauseError{}} =
               Client.request(:get, "/", nil, config: fake_config())
    end
  end

  describe "response decoding" do
    test "decodes the response body as JSON by default" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: %{"ok" => true}}} =
               Client.request(:get, "/", nil, config: [endpoint: "http://127.0.0.1:#{port}"])

      Task.await(server)
    end

    test "leaves the response body raw with format: :raw" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: @body}} =
               Client.request(:get, "/", nil,
                 config: [endpoint: "http://127.0.0.1:#{port}"],
                 format: :raw
               )

      Task.await(server)
    end

    test "encodes the request as JSON but leaves the response raw with split formats" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: @body}} =
               Client.request(:post, "/", %{"q" => 1},
                 config: [endpoint: "http://127.0.0.1:#{port}"],
                 req_format: :json,
                 resp_format: :raw
               )

      assert Task.await(server).body == ~s({"q":1})
    end

    test "keys: :atoms casts the decoded body's keys" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: %{ok: true}}} =
               Client.request(:get, "/", nil,
                 config: [endpoint: "http://127.0.0.1:#{port}"],
                 keys: :atoms
               )

      Task.await(server)
    end

    test "with the default codec_adapter, the body is plain decoded JSON (keys cast, no value casting)" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: %{"ok" => true}}} =
               Client.request(:get, "/", nil, config: [endpoint: "http://127.0.0.1:#{port}"])

      Task.await(server)
    end

    test "a config-configured codec_adapter is invoked automatically" do
      {port, server} = TCPTestServer.start(@response)
      config = Config.new(endpoint: "http://127.0.0.1:#{port}", codec_adapter: FakeCodec)

      assert {:ok, %Response{body: %{"ok" => true, "cast" => true}}} =
               Client.request(:get, "/", nil,
                 config: config,
                 codec_opts: [decode_fun: fn term, _opts -> Map.put(term, "cast", true) end]
               )

      Task.await(server)
    end

    test "a request-level codec_adapter overrides the config's" do
      {port, server} = TCPTestServer.start(@response)
      config = Config.new(endpoint: "http://127.0.0.1:#{port}")

      assert {:ok, %Response{body: %{"ok" => true, "cast" => true}}} =
               Client.request(:get, "/", nil,
                 config: config,
                 codec_adapter: FakeCodec,
                 codec_opts: [decode_fun: fn term, _opts -> Map.put(term, "cast", true) end]
               )

      Task.await(server)
    end

    test "returns {:error, %Error{}} for an invalid :keys" do
      assert {:error, %Error{reason: {:invalid_keys, :bogus_keys}}} =
               Client.request(:get, "/", nil,
                 config: [endpoint: "http://x:9200"],
                 keys: :bogus_keys
               )
    end
  end
end
