defmodule Dowser.Client.HTTP.TLSTest do
  @moduledoc """
  End-to-end TLS behaviour, against a real HTTPS server with a throw-away CA
  and a certificate issued for `search.internal` — never for the `127.0.0.1`
  the requests actually go to.
  """

  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP
  alias Dowser.Client.Response
  alias Dowser.Client.TLSTestServer

  @body ~s({"ok":true})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@body)}\r\n\r\n" <>
              @body

  setup_all do
    %{certificates: TLSTestServer.certificates()}
  end

  setup %{certificates: certificates} do
    {port, server} = TLSTestServer.start(@response, certificates.server)

    %{url: "https://127.0.0.1:#{port}/_search", server: server, cacerts: certificates.cacerts}
  end

  describe "by default" do
    test "rejects a certificate signed by an unknown CA", %{url: url} do
      assert {:error, reason} = HTTP.request(:get, url, [], nil, [])
      assert tls_alert(reason) in [:unknown_ca, :handshake_failure]
    end
  end

  describe "with the CA trusted" do
    # SNI can't carry an IP address, so the identity check for an IP host is
    # made by hand in a verify_fun — it must still reject a certificate issued
    # for some other name.
    test "still rejects a certificate issued for another host", %{url: url, cacerts: cacerts} do
      assert {:error, reason} = HTTP.request(:get, url, [], nil, ssl: [cacerts: cacerts])
      assert tls_alert(reason) in [:bad_certificate, :handshake_failure]
    end

    test "accepts a certificate carrying the IP address it was reached on" do
      certificates = TLSTestServer.certificates(iPAddress: [127, 0, 0, 1])
      {port, server} = TLSTestServer.start(@response, certificates.server)

      assert {:ok, %Response{status: 200}} =
               HTTP.request(:get, "https://127.0.0.1:#{port}/_search", [], nil,
                 ssl: [cacerts: certificates.cacerts]
               )

      assert Task.await(server).path == "/_search"
    end

    test "verify_hostname: false accepts it, chain verification intact", context do
      %{url: url, cacerts: cacerts, server: server} = context

      assert {:ok, %Response{status: 200, body: @body}} =
               HTTP.request(:get, url, [], nil, ssl: [cacerts: cacerts, verify_hostname: false])

      assert Task.await(server).path == "/_search"
    end

    test "sni: the certificate's own name also satisfies the hostname check", context do
      %{url: url, cacerts: cacerts, server: server} = context

      # The reference id httpc checks against is the URL's host, so a matching
      # SNI alone is not enough — this pins that `:sni` is passed through and
      # the handshake completes with it.
      assert {:ok, %Response{status: 200}} =
               HTTP.request(:get, url, [], nil,
                 ssl: [cacerts: cacerts, sni: "search.internal", verify_hostname: false]
               )

      assert Task.await(server).path == "/_search"
    end
  end

  describe "with verification off" do
    test "insecure: true accepts the unknown CA and the wrong hostname", context do
      %{url: url, server: server} = context

      assert {:ok, %Response{status: 200, body: @body}} =
               HTTP.request(:get, url, [], nil, ssl: [insecure: true])

      assert Task.await(server).path == "/_search"
    end

    test "it works through Dowser.Client.request/4, configured on the context", context do
      %{url: url, server: server} = context
      %URI{host: host, port: port} = URI.parse(url)

      context = [
        endpoint: "https://#{host}:#{port}",
        http_opts: [ssl: [insecure: true]]
      ]

      assert {:ok, %Response{status: 200, body: %{"ok" => true}}} =
               Dowser.Client.get("/_search", context: context)

      assert Task.await(server).path == "/_search"
    end
  end

  # :httpc reports a failed handshake as
  # {:failed_connect, [..., {:inet, [:inet], {:tls_alert, {alert, _description}}}]}.
  defp tls_alert({:failed_connect, details}) do
    details
    |> List.flatten()
    |> Enum.find_value(fn
      {:tls_alert, {alert, _description}} -> alert
      {_transport, _protocols, {:tls_alert, {alert, _description}}} -> alert
      _other -> nil
    end)
  end

  defp tls_alert(reason), do: reason
end
