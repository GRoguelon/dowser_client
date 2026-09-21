defmodule Dowser.Client.HTTP.Profile do
  @moduledoc """
  Manages the `:httpc` profiles `Dowser.Client.HTTP` sends requests through.

  A profile is an isolated `:httpc` manager with its own connection pool,
  session settings and cookie store. `dowser_client` never uses `:httpc`'s
  shared `:default` profile unless asked to, so its settings — and its
  keep-alive sessions — are never shared with the rest of the application.

  Profiles are started on demand, the first time a request needs one, and
  configured once with `:httpc.set_options/2`. Give each cluster its own
  profile when they should not share a connection pool:

      config :dowser_client,
        contexts: [
          default: [endpoint: "https://search.internal:9200", profile: :search],
          logs: [endpoint: "https://logs.internal:9200", profile: :logs]
        ]

  ## Options

  `:profile_opts` (on a context, globally, or per request) is passed to
  `:httpc.set_options/2`. `dowser_client`'s defaults, tuned for a search
  cluster rather than a browser:

    * `max_sessions: 20` — concurrent keep-alive connections per
      host/port (`:httpc`'s own default is 2, far too few for a search
      backend).
    * `max_keep_alive_length: 100` — requests queued on one session.
    * `keep_alive_timeout: 120_000` — how long an idle session is kept.
    * `cookies: :disabled` — a search API has no use for a cookie store.

  Anything `:httpc.set_options/2` accepts can be set: `:pipeline_timeout`,
  `:max_pipeline_length`, `:proxy`, `:https_proxy`, `:ipfamily`,
  `:socket_opts`, `:verbose`, `:unix_socket`, ...

      config :dowser_client, profile_opts: [max_sessions: 50, pipeline_timeout: 5_000]

  Because options are applied when the profile starts, changing them later has
  no effect until `reset/2` re-applies them.
  """

  ## Module attributes

  @default_profile :dowser_client

  @default_opts [
    max_sessions: 20,
    max_keep_alive_length: 100,
    keep_alive_timeout: 120_000,
    cookies: :disabled
  ]

  ## Typespecs

  @type t :: atom()

  ## Public functions

  @doc "The profile used when none is configured."
  @spec default() :: t()
  def default, do: @default_profile

  @doc "The `:httpc.set_options/2` defaults applied to every profile."
  @spec default_opts() :: keyword()
  def default_opts, do: @default_opts

  @doc """
  Ensures `name` is started and configured, returning `{:ok, name}`.

  Idempotent and cheap after the first call: the outcome is memoized in
  `:persistent_term`, so a steady-state request only reads a term.
  """
  @spec ensure_started(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def ensure_started(name, opts \\ [])

  def ensure_started(name, opts) when is_atom(name) and not is_nil(name) do
    if :persistent_term.get(key(name), false) do
      {:ok, name}
    else
      start(name, opts)
    end
  end

  def ensure_started(name, _opts) do
    {:error, {:invalid_profile, name}}
  end

  @doc """
  Re-applies `opts` to `name`, starting it if needed.

  Use it when profile options change at runtime — `ensure_started/2` only
  applies them once.
  """
  @spec reset(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def reset(name, opts \\ []) do
    invalidate(name)
    ensure_started(name, opts)
  end

  @doc """
  Forgets that `name` was started, so the next request starts and configures it
  again. Does not stop the profile.
  """
  @spec invalidate(t()) :: :ok
  def invalidate(name) when is_atom(name) do
    :persistent_term.erase(key(name))

    :ok
  end

  @doc """
  Reports `:httpc`'s own view of `name` — its open sessions, queued requests
  and current options. Handy for checking that keep-alive is doing what you
  expect.
  """
  @spec info(t()) :: list() | {:error, term()}
  def info(name \\ @default_profile) do
    :httpc.info(name)
  catch
    :exit, reason -> {:error, {:profile_down, reason}}
  end

  ## Private functions

  defp start(name, opts) do
    with {:ok, _apps} <- ensure_inets(),
         :ok <- start_profile(name),
         :ok <- set_options(name, opts) do
      :persistent_term.put(key(name), true)

      {:ok, name}
    end
  end

  defp ensure_inets do
    case Application.ensure_all_started(:inets) do
      {:ok, apps} -> {:ok, apps}
      {:error, reason} -> {:error, {:inets_not_started, reason}}
    end
  end

  # `:default` is :httpc's own always-running profile; only ours need starting.
  defp start_profile(:default), do: :ok

  defp start_profile(name) do
    case :inets.start(:httpc, [{:profile, name}]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:profile_start_failed, reason}}
    end
  end

  defp set_options(name, opts) do
    case :httpc.set_options(Keyword.merge(@default_opts, opts), name) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_profile_opts, reason}}
    end
  catch
    :exit, reason -> {:error, {:profile_down, reason}}
  end

  defp key(name), do: {__MODULE__, name}
end
