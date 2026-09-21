defmodule Dowser.ClientTest do
  use ExUnit.Case, async: false

  alias Dowser.Client
  alias Dowser.Client.Context
  alias Dowser.Client.Error
  alias Dowser.Client.HTTP.Error, as: HTTPError
  alias Dowser.Client.HTTP.FakeTransport
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

  describe "request/5 with a context in opts" do
    test "joins the endpoint with the path and injects basic-auth headers" do
      {port, server} = TCPTestServer.start(@response)
      context = Context.new(endpoint: "http://127.0.0.1:#{port}", auth: {:basic, "u", "p"})

      assert {:ok, %Response{status: 200, body: %{"ok" => true}}} =
               Client.request(:get, "/_search", nil,
                 context: context,
                 http_opts: [headers: [{"accept", "application/json"}]]
               )

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_search"
      assert req.headers["authorization"] == "Basic " <> Base.encode64("u:p")
      assert req.headers["accept"] == "application/json"
    end

    test "accepts inline keyword context and sends a raw body" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} =
               Client.request(:post, "/_bulk", "payload", context: context, format: :raw)

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_bulk"
      assert req.body == "payload"
    end

    test "encodes the body as JSON by default and sets content-type" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} =
               Client.request(:post, "/_search", %{"query" => %{"match_all" => %{}}},
                 context: context
               )

      req = Task.await(server)
      assert req.body == ~s({"query":{"match_all":{}}})
      assert req.headers["content-type"] == "application/json"
    end

    test "appends query params to the URL" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "/_search", nil,
                 context: context,
                 params: [routing: "u1", refresh: true]
               )

      assert Task.await(server).path == "/_search?routing=u1&refresh=true"
    end

    test "an absolute URL overrides the context endpoint" do
      {port, server} = TCPTestServer.start(@response)
      context = Context.new(endpoint: "http://elsewhere:9200")

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "http://127.0.0.1:#{port}/", nil, context: context)

      assert Task.await(server).path == "/"
    end
  end

  describe "get/2, post/3, put/3, patch/3, delete/3 convenience wrappers" do
    test "every wrapper's opts (and post/put/patch's body) default when omitted" do
      Application.delete_env(:dowser_client, :contexts)

      # No :context given and no :default configured — each should still
      # reach real option resolution (proving the \\ nil / \\ [] defaults
      # are wired through) and fail the same documented way.
      assert {:error, %Error{reason: {:unknown_context, :default}}} = Client.get("/x")
      assert {:error, %Error{reason: {:unknown_context, :default}}} = Client.post("/x")
      assert {:error, %Error{reason: {:unknown_context, :default}}} = Client.put("/x")
      assert {:error, %Error{reason: {:unknown_context, :default}}} = Client.patch("/x")
      assert {:error, %Error{reason: {:unknown_context, :default}}} = Client.delete("/x")
    end

    test "get/2 issues a GET with no body" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.get("/_search", context: context)
      req = Task.await(server)
      assert req.method == "GET"
      assert req.body == ""
    end

    test "post/3 issues a POST with the given body" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.post("/_bulk", %{"a" => 1}, context: context)
      req = Task.await(server)
      assert req.method == "POST"
      assert req.body == ~s({"a":1})
    end

    test "put/3 issues a PUT with the given body" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.put("/doc/1", %{"a" => 1}, context: context)
      assert Task.await(server).method == "PUT"
    end

    test "patch/3 issues a PATCH with the given body" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.patch("/doc/1", %{"a" => 1}, context: context)
      assert Task.await(server).method == "PATCH"
    end

    test "delete/3 issues a DELETE, defaulting its body to nil" do
      {port, server} = TCPTestServer.start(@response)
      context = [endpoint: "http://127.0.0.1:#{port}"]

      assert {:ok, %Response{status: 200}} = Client.delete("/doc/1", nil, context: context)
      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.body == ""
    end
  end

  describe "request/4 error handling" do
    test "returns {:error, %HTTP.Error{}} when the connection fails" do
      port = TCPTestServer.free_port()
      context = Context.new(endpoint: "http://127.0.0.1:#{port}")

      assert {:error, %HTTPError{} = error} =
               Client.request(:get, "/", nil, context: context, retry: false)

      assert error.method == :get
      assert error.reason != nil
    end

    test "returns {:error, %Error{}} for an unconfigured context atom" do
      Application.delete_env(:dowser_client, :contexts)

      assert {:error, %Error{reason: {:unknown_context, :nope}}} =
               Client.request(:get, "/", nil, context: :nope)
    end

    test "returns {:error, %Error{}} when :context is omitted and no :default is configured" do
      Application.delete_env(:dowser_client, :contexts)

      assert {:error, %Error{reason: {:unknown_context, :default}}} =
               Client.request(:get, "/", nil, [])
    end

    test "returns {:error, %Error{}} for an invalid :format" do
      assert {:error, %Error{reason: {:invalid_format, :xml}}} =
               Client.request(:get, "/", nil, context: [endpoint: "http://x:9200"], format: :xml)
    end

    test "returns {:error, %Error{}} when :format conflicts with :req_format" do
      assert {:error, %Error{reason: :conflicting_formats}} =
               Client.request(:get, "/", nil,
                 context: [endpoint: "http://x:9200"],
                 format: :json,
                 req_format: :raw
               )
    end

    test "returns {:error, %JSON.Error{}} when the body cannot be encoded" do
      context = [endpoint: "http://x:9200"]

      assert {:error, %JSONError{operation: :encode}} =
               Client.request(:post, "/", {:not, :encodable}, context: context)
    end

    test "returns {:error, %JSON.Error{}} when the response body cannot be decoded" do
      html = "<html>bad</html>"
      response = "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(html)}\r\n\r\n" <> html
      {port, server} = TCPTestServer.start(response)

      assert {:error, %JSONError{operation: :decode}} =
               Client.request(:get, "/", nil, context: [endpoint: "http://127.0.0.1:#{port}"])

      Task.await(server)
    end
  end

  describe "retry" do
    test "an unscripted transport returns {:error, :no_script}" do
      FakeTransport.script([])

      assert {:error, %HTTPError{reason: :no_script}} =
               Client.request(:get, "/", nil, context: fake_config(), retry: false)
    end

    test "retries a transient error until it succeeds" do
      transport =
        FakeTransport.script([
          {:error, :timeout},
          {:error, :timeout},
          {:ok, %Response{status: 200}}
        ])

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "/", nil, context: fake_config(), retry: [base_delay_ms: 1])

      assert FakeTransport.calls(transport) == 3
    end

    test "exhausts max_attempts and wraps the last error with the attempt count" do
      transport = FakeTransport.script([{:error, :timeout}])

      assert {:error, %HTTPError{reason: :timeout, attempts: 3}} =
               Client.request(:get, "/", nil,
                 context: fake_config(),
                 retry: [max_attempts: 3, base_delay_ms: 1]
               )

      assert FakeTransport.calls(transport) == 3
    end

    test "retry: false performs exactly one attempt" do
      transport = FakeTransport.script([{:error, :timeout}, {:ok, %Response{status: 200}}])

      assert {:error, %HTTPError{attempts: 1}} =
               Client.request(:get, "/", nil, context: fake_config(), retry: false)

      assert FakeTransport.calls(transport) == 1
    end

    test "a non-retryable status passes straight through" do
      transport = FakeTransport.script([{:ok, %Response{status: 404}}])

      assert {:ok, %Response{status: 404}} =
               Client.request(:get, "/", nil, context: fake_config(), format: :raw)

      assert FakeTransport.calls(transport) == 1
    end

    test "a retryable status is retried until success" do
      transport =
        FakeTransport.script([{:ok, %Response{status: 503}}, {:ok, %Response{status: 200}}])

      assert {:ok, %Response{status: 200}} =
               Client.request(:get, "/", nil,
                 context: fake_config(),
                 format: :raw,
                 retry: [base_delay_ms: 1]
               )

      assert FakeTransport.calls(transport) == 2
    end

    test "a non-transient error is not retried" do
      transport = FakeTransport.script([{:error, :enoent}])

      assert {:error, %HTTPError{reason: :enoent, attempts: 1}} =
               Client.request(:get, "/", nil, context: fake_config())

      assert FakeTransport.calls(transport) == 1
    end

    # `perform/1`'s `rescue` clause catches anything unexpected raised while
    # running the request/retry pipeline (not just {:error, _} tuples from the
    # transport) and turns it into an {:error, exception} instead of crashing
    # the caller.
    test "an unexpected exception raised while running the request is caught and returned" do
      FakeTransport.script([:not_a_valid_result])

      assert {:error, %FunctionClauseError{}} =
               Client.request(:get, "/", nil, context: fake_config())
    end

    defp fake_config do
      Context.new(endpoint: "http://fake")
    end
  end

  describe "response decoding" do
    test "decodes the response body as JSON by default" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: %{"ok" => true}}} =
               Client.request(:get, "/", nil, context: [endpoint: "http://127.0.0.1:#{port}"])

      Task.await(server)
    end

    test "leaves the response body raw with format: :raw" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: @body}} =
               Client.request(:get, "/", nil,
                 context: [endpoint: "http://127.0.0.1:#{port}"],
                 format: :raw
               )

      Task.await(server)
    end

    test "encodes the request as JSON but leaves the response raw with split formats" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: @body}} =
               Client.request(:post, "/", %{"q" => 1},
                 context: [endpoint: "http://127.0.0.1:#{port}"],
                 req_format: :json,
                 resp_format: :raw
               )

      assert Task.await(server).body == ~s({"q":1})
    end

    test "keys: :atoms casts the decoded body's keys" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: %{ok: true}}} =
               Client.request(:get, "/", nil,
                 context: [endpoint: "http://127.0.0.1:#{port}"],
                 keys: :atoms
               )

      Task.await(server)
    end

    test "without :keys or :decoder, the body is the plain decoded JSON" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{body: %{"ok" => true}}} =
               Client.request(:get, "/", nil, context: [endpoint: "http://127.0.0.1:#{port}"])

      Task.await(server)
    end

    test "a context-configured :keys is applied automatically" do
      {port, server} = TCPTestServer.start(@response)
      context = Context.new(endpoint: "http://127.0.0.1:#{port}", keys: :atoms)

      assert {:ok, %Response{body: %{ok: true}}} =
               Client.request(:get, "/", nil, context: context)

      Task.await(server)
    end

    test "a request-level :keys overrides the context's" do
      {port, server} = TCPTestServer.start(@response)
      context = Context.new(endpoint: "http://127.0.0.1:#{port}", keys: :atoms)

      assert {:ok, %Response{body: %{"ok" => true}}} =
               Client.request(:get, "/", nil, context: context, keys: :strings)

      Task.await(server)
    end

    test "returns {:error, %Error{}} for an invalid :keys" do
      assert {:error, %Error{reason: {:invalid_keys, :bogus_keys}}} =
               Client.request(:get, "/", nil,
                 context: [endpoint: "http://x:9200"],
                 keys: :bogus_keys
               )
    end

    test "returns {:error, %Error{}} for an invalid :decoder" do
      assert {:error, %Error{reason: {:invalid_decoder, :nope}}} =
               Client.request(:get, "/", nil,
                 context: [endpoint: "http://x:9200"],
                 decoder: :nope
               )
    end

    test "a context-configured :encoder runs on the source a request points at" do
      {port, server} = TCPTestServer.start(@response)

      context =
        Context.new(
          endpoint: "http://127.0.0.1:#{port}",
          encoder:
            {fn source, opts -> Map.put(source, "from", opts[:index]) end, index: "articles"}
        )

      assert {:ok, %Response{status: 200}} =
               Client.post("/articles/_update/1", %{"doc" => %{"t" => "x"}},
                 context: context,
                 encode: ["doc"]
               )

      assert Task.await(server).body == ~s({"doc":{"from":"articles","t":"x"}})
    end

    test "a search body is never encoded, even with an :encoder configured" do
      {port, server} = TCPTestServer.start(@response)

      context =
        Context.new(
          endpoint: "http://127.0.0.1:#{port}",
          encoder: fn _source, _opts -> raise "never called" end
        )

      assert {:ok, %Response{status: 200}} =
               Client.post("/articles/_search", %{"q" => 1}, context: context)

      assert Task.await(server).body == ~s({"q":1})
    end

    test "a context-configured :decoder owns the decoded body" do
      {port, server} = TCPTestServer.start(@response)

      context =
        Context.new(
          endpoint: "http://127.0.0.1:#{port}",
          decoder: {fn body, opts -> {body, opts[:flag]} end, flag: :set}
        )

      assert {:ok, %Response{body: {%{"ok" => true}, :set}}} =
               Client.request(:get, "/", nil, context: context)

      Task.await(server)
    end
  end
end
