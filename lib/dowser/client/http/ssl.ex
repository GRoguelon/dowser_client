defmodule Dowser.Client.HTTP.SSL do
  @moduledoc """
  Builds the `:ssl` options `Dowser.Client.HTTP` hands to `:httpc` for an
  `https://` URL.

  Secure by default: the chain is verified against the OS trust store
  (`:public_key.cacerts_get/0`), the certificate's identity is checked against
  the URL's host, SNI is sent, and TLS is restricted to 1.2+.

  ## Options

  `http_opts[:ssl]` is a keyword list. The keys below are interpreted here;
  every other key is passed through to `:ssl` verbatim (so
  `ssl: [reuse_sessions: false]` works), and overrides the computed value for
  that key.

    * `:verify` — `true` (default) for `:verify_peer`, `false` for
      `:verify_none`. The `:ssl` atoms `:verify_peer`/`:verify_none` are also
      accepted.
    * `:insecure` — `true` is shorthand for `verify: false`: no chain and no
      hostname verification at all. For a `localhost` cluster with a
      self-signed certificate, or a dev box you own.
    * `:verify_hostname` — `true` (default) checks the certificate identity
      against the URL host. `false` keeps full chain verification but accepts
      any name in the certificate — the option for an SSH tunnel or a
      port-forward, where the host you connect to is never the host the
      certificate was issued for.
    * `:cacerts` / `:cacertfile` — an explicit trust store, replacing the OS
      one. `:cacertfile` accepts a string path.
    * `:sni` — the server name to send. `:auto` (default) sends the URL host,
      except for an IP address, where SNI is disabled (an IP is not a legal
      SNI value). `:disable` never sends it; a string sends that name.
    * `:versions` — TLS versions; defaults to `[:"tlsv1.2", :"tlsv1.3"]`.
    * `:depth` — maximum intermediate certificates; defaults to `3`.

  ## Examples

      # localhost with a self-signed certificate
      ssl: [insecure: true]

      # SSH tunnel: real CA, but the hostname will never match
      ssl: [verify_hostname: false]

      # a private CA
      ssl: [cacertfile: "/etc/ssl/certs/internal-ca.pem"]
  """

  ## Module attributes

  @default_versions [:"tlsv1.2", :"tlsv1.3"]

  @default_depth 3

  ## Typespecs

  @type opts :: keyword()

  ## Public functions

  @doc """
  Returns `{:ok, ssl_options}` for an `https://` URL, `{:ok, nil}` for any
  other scheme (`:httpc` ignores `:ssl` there), or `{:error, reason}` when the
  options cannot be built — e.g. no trust store is available and none was
  given.
  """
  @spec options(String.t(), opts()) :: {:ok, keyword() | nil} | {:error, term()}
  def options(url, ssl_opts \\ []) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        build(host, ssl_opts)

      %URI{scheme: "https"} ->
        {:error, {:invalid_url, url}}

      %URI{} ->
        {:ok, nil}
    end
  end

  ## Private functions

  defp build(host, ssl_opts) do
    {insecure?, ssl_opts} = Keyword.pop(ssl_opts, :insecure, false)
    {verify, ssl_opts} = Keyword.pop(ssl_opts, :verify, not insecure?)
    {verify_hostname?, ssl_opts} = Keyword.pop(ssl_opts, :verify_hostname, true)
    {sni, ssl_opts} = Keyword.pop(ssl_opts, :sni, :auto)
    ssl_opts = normalize_cacertfile(ssl_opts)

    if verify_peer?(verify) do
      verified(host, sni, verify_hostname?, ssl_opts)
    else
      {:ok, Keyword.merge([verify: :verify_none, versions: @default_versions], ssl_opts)}
    end
  end

  defp verified(host, sni, verify_hostname?, ssl_opts) do
    with {:ok, trust_store} <- trust_store(ssl_opts) do
      computed =
        [verify: :verify_peer, depth: @default_depth, versions: @default_versions] ++
          identity(host, sni, verify_hostname?) ++ trust_store

      {:ok, Keyword.merge(computed, ssl_opts)}
    end
  end

  # `:ssl` derives the identity to check the certificate against from
  # `:server_name_indication`, so wherever SNI can't carry it — an IP address
  # host, or SNI explicitly disabled — the check has to be made by hand in a
  # `:verify_fun`, or it would silently not happen at all.
  defp identity(host, sni, true) do
    case sni(sni, host) do
      :disable ->
        [
          server_name_indication: :disable,
          # `:ssl`'s own check can only fail with no SNI to check against, so
          # it's waved through and `verify_fun` becomes the authority.
          customize_hostname_check: [match_fun: fn _reference, _presented -> true end],
          verify_fun: {&verify_identity/3, reference_id(host)}
        ]

      name ->
        [
          server_name_indication: name,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
    end
  end

  # A match_fun returning `true` accepts whatever name the certificate
  # presents, leaving chain verification untouched.
  defp identity(host, sni, false) do
    [
      server_name_indication: sni(sni, host),
      customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
    ]
  end

  defp reference_id(host) do
    if ip?(host), do: {:ip, to_charlist(host)}, else: {:dns_id, to_charlist(host)}
  end

  # Replaces `:ssl`'s default verify_fun, so it must handle the whole chain the
  # same way and only add the identity check on the peer certificate.
  defp verify_identity(_cert, {:bad_cert, reason}, _reference_id) do
    {:fail, reason}
  end

  defp verify_identity(_cert, {:extension, _extension}, reference_id) do
    {:unknown, reference_id}
  end

  defp verify_identity(_cert, :valid, reference_id) do
    {:valid, reference_id}
  end

  defp verify_identity(cert, :valid_peer, reference_id) do
    match_fun = :public_key.pkix_verify_hostname_match_fun(:https)

    if :public_key.pkix_verify_hostname(cert, [reference_id], match_fun: match_fun) do
      {:valid, reference_id}
    else
      {:fail, :hostname_check_failed}
    end
  end

  defp verify_peer?(:verify_none), do: false
  defp verify_peer?(verify), do: !!verify

  # An explicit trust store wins; it stays in `ssl_opts` and is merged over the
  # computed options, so nothing needs to be added here.
  defp trust_store(ssl_opts) do
    if Keyword.has_key?(ssl_opts, :cacerts) or Keyword.has_key?(ssl_opts, :cacertfile) do
      {:ok, []}
    else
      os_trust_store()
    end
  end

  defp os_trust_store do
    {:ok, [cacerts: :public_key.cacerts_get()]}
  rescue
    exception -> {:error, {:no_cacerts, exception}}
  end

  defp normalize_cacertfile(ssl_opts) do
    case Keyword.fetch(ssl_opts, :cacertfile) do
      {:ok, path} when is_binary(path) -> Keyword.put(ssl_opts, :cacertfile, to_charlist(path))
      _other -> ssl_opts
    end
  end

  # Sending an IP address as SNI is invalid, so it's disabled for one.
  defp sni(:auto, host) do
    if ip?(host), do: :disable, else: to_charlist(host)
  end

  defp sni(:disable, _host), do: :disable
  defp sni(name, _host) when is_binary(name), do: to_charlist(name)
  defp sni(name, _host), do: name

  defp ip?(host) do
    match?({:ok, _address}, host |> to_charlist() |> :inet.parse_address())
  end
end
