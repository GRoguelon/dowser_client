defmodule Dowser.Client.HTTP.DefaultTimeoutsTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP
  alias Dowser.Client.Retry
  alias Dowser.Client.TCPTestServer

  describe "Httpc" do
    test "http_options[:timeout] overrides the default receive timeout" do
      url = "http://127.0.0.1:#{TCPTestServer.start_slow()}/"

      {elapsed, result} =
        :timer.tc(fn -> HTTP.Httpc.request(:get, url, [], nil, http_options: [timeout: 50]) end)

      assert {:error, _reason} = result
      assert elapsed < 1_000_000
    end
  end

  describe "Req" do
    @describetag :req

    test "receive_timeout overrides the default" do
      if Code.ensure_loaded?(Req) do
        url = "http://127.0.0.1:#{TCPTestServer.start_slow()}/"

        {elapsed, result} =
          :timer.tc(fn -> HTTP.Req.request(:get, url, [], nil, receive_timeout: 50) end)

        assert {:error, _reason} = result
        assert elapsed < 1_000_000
      end
    end

    # Contrast with Httpc, which rejects a body on GET entirely (see
    # HttpcTest's "body given for a method that doesn't support one") — Req
    # doesn't reject it, but Req's own default `encode_body` step silently
    # rewrites GET-with-a-body to POST (see `get_to_post/1` in
    # `Req.Steps`) — the body still reaches the server, but not as a GET.
    test "sends a body given for GET, but Req itself rewrites the method to POST" do
      if Code.ensure_loaded?(Req) do
        body = ~s({"query":{"match_all":{}}})
        response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        {port, server} = TCPTestServer.start(response)
        url = "http://127.0.0.1:#{port}/_search"

        assert {:ok, %Dowser.Client.Response{status: 200}} =
                 HTTP.Req.request(:get, url, [], body, [])

        req = Task.await(server)
        assert req.method == "POST"
        assert req.body == body
      end
    end
  end

  describe "Hackney" do
    @describetag :hackney

    test "recv_timeout overrides the default" do
      if Code.ensure_loaded?(:hackney) do
        url = "http://127.0.0.1:#{TCPTestServer.start_slow()}/"

        {elapsed, result} =
          :timer.tc(fn -> HTTP.Hackney.request(:get, url, [], nil, recv_timeout: 50) end)

        assert {:error, _reason} = result
        assert elapsed < 1_000_000
      end
    end

    test "a real connection-refused error is classified as transient" do
      if Code.ensure_loaded?(:hackney) do
        url = "http://127.0.0.1:#{TCPTestServer.free_port()}/"

        assert {:error, reason} = HTTP.Hackney.request(:get, url, [], nil, [])
        assert Retry.transient?(reason), "expected #{inspect(reason)} to be classified transient"
      end
    end

    # Contrast with Httpc, which rejects a body on GET entirely.
    test "sends a body on GET (unlike Httpc, which rejects it)" do
      if Code.ensure_loaded?(:hackney) do
        body = ~s({"query":{"match_all":{}}})
        response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        {port, server} = TCPTestServer.start(response)
        url = "http://127.0.0.1:#{port}/_search"

        assert {:ok, %Dowser.Client.Response{status: 200}} =
                 HTTP.Hackney.request(:get, url, [], body, [])

        req = Task.await(server)
        assert req.method == "GET"
        assert req.body == body
      end
    end
  end
end
