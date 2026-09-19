defmodule Dowser.Client.HTTPTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP
  alias Dowser.Client.Response
  alias Dowser.Client.Retry
  alias Dowser.Client.TCPTestServer

  @body ~s({"ok":true})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@body)}\r\n\r\n" <>
              @body

  describe "request/5" do
    test "performs a GET and normalizes the response" do
      {port, server} = TCPTestServer.start(@response)
      url = "http://127.0.0.1:#{port}/_search"

      assert {:ok, %Response{status: 200, body: body, headers: headers}} =
               HTTP.request(:get, url, [{"accept", "application/json"}], nil, [])

      assert body == @body
      assert headers["content-type"] == "application/json"

      request = Task.await(server)
      assert request.method == "GET"
      assert request.path == "/_search"
      assert request.headers["accept"] == "application/json"
    end

    test "sends a request body with a content-type header" do
      {port, server} = TCPTestServer.start(@response)
      url = "http://127.0.0.1:#{port}/_bulk"
      body = ~s({"query":{"match_all":{}}})

      assert {:ok, %Response{status: 200}} =
               HTTP.request(:post, url, [{"content-type", "application/json"}], body, [])

      request = Task.await(server)
      assert request.method == "POST"
      assert request.body == body
      assert request.headers["content-type"] == "application/json"
    end

    test "accepts headers given as a map" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{status: 200}} =
               HTTP.request(:get, "http://127.0.0.1:#{port}/", %{"X-Test" => "value"}, nil, [])

      assert Task.await(server).headers["x-test"] == "value"
    end

    test "a connection-refused error is returned and classified transient" do
      url = "http://127.0.0.1:#{TCPTestServer.free_port()}/"

      assert {:error, reason} = HTTP.request(:get, url, [], nil, [])
      assert Retry.transient?(reason), "expected #{inspect(reason)} to be classified transient"
    end
  end

  # `:httpc` never speaks HTTP/2 and keeps sessions alive per host/port. The
  # server here accepts exactly ONE connection and then closes its listener,
  # serving two sequential requests on that single socket: a transport that
  # didn't reuse the connection would have its second request refused.
  describe "HTTP/1.1 and keep-alive" do
    @keep_alive_response "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(@body)}\r\nConnection: keep-alive\r\n\r\n" <>
                           @body

    test "sends HTTP/1.1 and reuses one keep-alive connection" do
      {port, server} = TCPTestServer.start_keep_alive(@keep_alive_response, 2)
      url = "http://127.0.0.1:#{port}/"

      assert {:ok, %Response{status: 200}} = HTTP.request(:get, url, [], nil, [])

      assert {:ok, %Response{status: 200}} = HTTP.request(:get, url, [], nil, []),
             "second request failed — connection not reused"

      requests = Task.await(server, 5000)

      assert length(requests) == 2
      assert Enum.all?(requests, &(&1.version == "HTTP/1.1"))
    end
  end

  describe "a body on a method :httpc has no body slot for" do
    test "a GET carrying a body is sent as a POST" do
      body = ~s({"query":{"match_all":{}}})
      {port, server} = TCPTestServer.start(@response)
      url = "http://127.0.0.1:#{port}/_search"

      assert {:ok, %Response{status: 200}} = HTTP.request(:get, url, [], body, [])

      request = Task.await(server)
      assert request.method == "POST"
      assert request.body == body
    end

    test "a GET with a nil or empty body stays a GET" do
      for body <- [nil, "", []] do
        {port, server} = TCPTestServer.start(@response)
        url = "http://127.0.0.1:#{port}/"

        assert {:ok, %Response{status: 200}} = HTTP.request(:get, url, [], body, [])
        assert Task.await(server).method == "GET"
      end
    end

    test "a body on HEAD is an error rather than silently dropped" do
      assert {:error, {:unsupported_body, :head}} =
               HTTP.request(:head, "http://127.0.0.1:1/", [], "some body", [])
    end

    test "a GET with a body surfaces as a POST through Dowser.Client.request/4" do
      body = ~s({"query":{"match_all":{}}})
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{status: 200, body: %{"ok" => true}}} =
               Dowser.Client.request(:get, "/_search", %{query: %{match_all: %{}}},
                 context: [endpoint: "http://127.0.0.1:#{port}"]
               )

      request = Task.await(server)
      assert request.method == "POST"
      assert request.body == body
    end
  end

  describe "options" do
    test ":timeout overrides the default receive timeout" do
      url = "http://127.0.0.1:#{TCPTestServer.start_slow()}/"

      {elapsed, result} = :timer.tc(fn -> HTTP.request(:get, url, [], nil, timeout: 50) end)

      assert {:error, :timeout} = result
      assert elapsed < 1_000_000
    end

    test ":connect_timeout is accepted" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{status: 200}} =
               HTTP.request(:get, "http://127.0.0.1:#{port}/", [], nil, connect_timeout: 1_000)

      Task.await(server)
    end

    test ":http_options and :options are merged last as escape hatches" do
      url = "http://127.0.0.1:#{TCPTestServer.start_slow()}/"

      {elapsed, result} =
        :timer.tc(fn ->
          HTTP.request(:get, url, [], nil,
            timeout: 30_000,
            http_options: [timeout: 50],
            options: [full_result: true]
          )
        end)

      assert {:error, :timeout} = result
      assert elapsed < 1_000_000
    end

    test "an unknown option is an error rather than silently ignored" do
      assert {:error, {:unknown_http_opts, [:recv_timeout]}} =
               HTTP.request(:get, "http://127.0.0.1:1/", [], nil, recv_timeout: 50)
    end

    test "surfaces through Dowser.Client.request/4 as a Dowser.Client.HTTP.Error" do
      assert {:error, %HTTP.Error{reason: reason, profile: :dowser_client}} =
               Dowser.Client.request(:get, "/", nil,
                 context: [endpoint: "http://127.0.0.1:1"],
                 http_opts: [nope: true],
                 retry: false
               )

      assert reason == {:unknown_http_opts, [:nope]}
    end
  end

  describe "profiles" do
    test "requests go through the configured profile" do
      {port, server} = TCPTestServer.start(@response)

      assert {:ok, %Response{status: 200}} =
               HTTP.request(:get, "http://127.0.0.1:#{port}/", [], nil,
                 profile: :dowser_test_http,
                 profile_opts: [max_sessions: 3]
               )

      Task.await(server)

      assert {:ok, 3} =
               Keyword.fetch(HTTP.Profile.info(:dowser_test_http)[:options], :max_sessions)
    end
  end
end
