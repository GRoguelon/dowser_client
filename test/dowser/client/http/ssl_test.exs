defmodule Dowser.Client.HTTP.SSLTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.HTTP.SSL

  describe "options/2 for a non-https URL" do
    test "returns nil — :httpc has no use for TLS options there" do
      assert {:ok, nil} = SSL.options("http://localhost:9200/_search")
    end
  end

  describe "options/2 defaults" do
    test "verifies the chain against the OS trust store and checks the hostname" do
      assert {:ok, opts} = SSL.options("https://search.internal:9200/_search")

      assert opts[:verify] == :verify_peer
      assert opts[:depth] == 3
      assert opts[:versions] == [:"tlsv1.2", :"tlsv1.3"]
      assert opts[:server_name_indication] == ~c"search.internal"
      assert is_list(opts[:cacerts]) and opts[:cacerts] != []

      assert opts[:customize_hostname_check][:match_fun] ==
               :public_key.pkix_verify_hostname_match_fun(:https)
    end

    test "disables SNI for an IP-address host, which cannot legally be sent as one" do
      assert {:ok, opts} = SSL.options("https://127.0.0.1:9200/")

      assert opts[:server_name_indication] == :disable
      assert opts[:verify] == :verify_peer
    end
  end

  describe "options/2 with verification off" do
    test "insecure: true skips verification entirely" do
      assert {:ok, opts} = SSL.options("https://localhost:9200/", insecure: true)

      assert opts[:verify] == :verify_none
      assert opts[:versions] == [:"tlsv1.2", :"tlsv1.3"]
      refute Keyword.has_key?(opts, :cacerts)
      refute Keyword.has_key?(opts, :customize_hostname_check)
    end

    test "verify: false does the same" do
      assert {:ok, opts} = SSL.options("https://localhost:9200/", verify: false)

      assert opts[:verify] == :verify_none
    end

    test "verify: :verify_none is accepted as :ssl spells it" do
      assert {:ok, opts} = SSL.options("https://localhost:9200/", verify: :verify_none)

      assert opts[:verify] == :verify_none
    end
  end

  describe "options/2 with verify_hostname: false" do
    test "keeps chain verification but accepts any name in the certificate" do
      assert {:ok, opts} = SSL.options("https://localhost:9200/", verify_hostname: false)

      assert opts[:verify] == :verify_peer
      assert is_list(opts[:cacerts])

      match_fun = opts[:customize_hostname_check][:match_fun]
      assert is_function(match_fun, 2)
      assert match_fun.({:dns_id, ~c"localhost"}, {:dNSName, ~c"some-other-host"})
    end
  end

  describe "options/2 with an explicit trust store" do
    test ":cacertfile replaces the OS one, as a charlist path" do
      assert {:ok, opts} =
               SSL.options("https://localhost:9200/", cacertfile: "/etc/ssl/internal-ca.pem")

      assert opts[:cacertfile] == ~c"/etc/ssl/internal-ca.pem"
      refute Keyword.has_key?(opts, :cacerts)
    end

    test ":cacerts replaces the OS one" do
      assert {:ok, opts} = SSL.options("https://localhost:9200/", cacerts: [<<1, 2, 3>>])

      assert opts[:cacerts] == [<<1, 2, 3>>]
    end
  end

  describe "options/2 passthrough and overrides" do
    test "an unrecognized key is passed to :ssl verbatim" do
      assert {:ok, opts} = SSL.options("https://localhost:9200/", reuse_sessions: false)

      assert opts[:reuse_sessions] == false
      assert opts[:verify] == :verify_peer
    end

    test "a given key overrides the computed value" do
      assert {:ok, opts} =
               SSL.options("https://localhost:9200/", versions: [:"tlsv1.3"], depth: 9)

      assert opts[:versions] == [:"tlsv1.3"]
      assert opts[:depth] == 9
    end

    test ":sni sets or disables the server name" do
      assert {:ok, opts} = SSL.options("https://localhost:9200/", sni: "search.internal")
      assert opts[:server_name_indication] == ~c"search.internal"

      assert {:ok, opts} = SSL.options("https://localhost:9200/", sni: :disable)
      assert opts[:server_name_indication] == :disable
    end
  end

  describe "options/2 with an unusable URL" do
    test "an https URL with no host is an error" do
      assert {:error, {:invalid_url, "https://"}} = SSL.options("https://")
    end
  end
end
