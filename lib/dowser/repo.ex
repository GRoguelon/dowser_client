defmodule Dowser.Repo do
  @moduledoc """
  A repo is one cluster an application talks to: where it is, how to
  authenticate, which connection pool to use and how to cast what it returns.

  A backend package builds on this module (`use Dowser.OpenSearch.Repo`,
  `use Dowser.Elasticsearch.Repo`); an application defines one module per
  cluster:

      defmodule MyApp.Search do
        use Dowser.OpenSearch.Repo, otp_app: :my_app
      end

  configures it under its own application, like an `Ecto.Repo`:

      # config/runtime.exs
      config :my_app, MyApp.Search,
        endpoint: System.fetch_env!("OPENSEARCH_URL"),
        auth: {:basic, "app", System.fetch_env!("OPENSEARCH_PASSWORD")},
        profile_opts: [max_sessions: 50]

  and starts it in its supervision tree:

      children = [MyApp.Repo, MyApp.Search, MyAppWeb.Endpoint]

  Every request then names it — `repo: MyApp.Search` — or falls back to the
  backend's default repo (`config :dowser_opensearch, default_repo:
  MyApp.Search`).

  ## Configuration

  The keys of `Dowser.Client.Context`, read from `config :otp_app, Repo`, then
  passed through `c:init/2`:

    * `:endpoint` (required), `:auth`, `:http_opts`, `:keys`, `:decoder`,
      `:encoder` — see `Dowser.Client.Context`.
    * `:profile` — the `:httpc` profile; defaults to the repo module itself, so
      each repo has its own connection pool. `:profile_opts` configures it.
    * `:verify` — check at startup that the endpoint is the engine the backend
      package expects, and fail to start otherwise (default `false`). A
      cluster that is down then stops the application from booting, which is
      why it is off by default.

  ## Started or not

  Started, a repo resolves its configuration once — `c:init/2` included — and
  keeps the result in `:persistent_term`, so a request only reads a term.

  Not started — a script, a Mix task, `iex -S mix` without the application — a
  repo still works: its configuration is resolved on every request, with
  `c:init/2` called as `init(:runtime, config)`.

  ## The HTTP verbs

  A repo exposes `request/4` and the verbs over it — `get/2`, `post/3`,
  `put/3`, `patch/3`, `delete/3` and `head/2` — taking a path relative to the
  endpoint, for any endpoint the API modules don't cover:

      MyApp.Search.post("/_plugins/_ml/models/_search", %{query: %{match_all: %{}}})

  They return `Dowser.Client.request/4`'s result (`{:ok, %Dowser.Client.Response{}}`
  for any status). Being `c:request/4` callbacks, they are also the seam a
  test can replace with a mock repo.
  """

  alias Dowser.Client.Context

  ## Behaviour callbacks

  @doc """
  Adjusts the configuration before the repo uses it — the place for secrets
  that can't live in config files.

  `type` is `:supervisor` when the repo starts, `:runtime` when it resolves
  its configuration without having been started. Return `{:ok, config}` or
  `:ignore` (not started; `:supervisor` only).
  """
  @callback init(type :: :supervisor | :runtime, config :: keyword()) ::
              {:ok, keyword()} | :ignore

  @doc "Runs a request against this repo; see `Dowser.Client.request/4`."
  @callback request(Dowser.Client.method(), String.t(), term(), keyword()) ::
              Dowser.Client.result()

  @doc """
  Checks that `context` points at the engine the backend package expects,
  returning what it found (e.g. `{:opensearch, "2.15.0"}`).
  """
  @callback verify(Context.t()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks init: 2, verify: 1

  ## Typespecs

  @typedoc "A repo module, or the attributes of an ad-hoc one (`[endpoint: ...]`)."
  @type t :: module() | keyword() | map() | Context.t()

  ## The `use` macro

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      @behaviour Dowser.Repo

      @doc false
      def __otp_app__, do: unquote(otp_app)

      @doc "A child spec starting this repo; see `Dowser.Repo`."
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
      end

      @doc """
      Starts this repo, merging `opts` over its configuration; see `Dowser.Repo`.
      """
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        Dowser.Repo.start_link(__MODULE__, opts)
      end

      @doc "This repo's resolved configuration, as a `Dowser.Client.Context`."
      @spec context() :: Dowser.Client.Context.t()
      def context do
        Dowser.Repo.context(__MODULE__)
      end

      @doc """
      What `verify/1` found when the repo started with `verify: true`, or `nil`.
      """
      @spec engine() :: term() | nil
      def engine do
        Dowser.Repo.engine(__MODULE__)
      end

      @impl Dowser.Repo
      def request(method, path, body \\ nil, opts \\ []) do
        Dowser.Client.request(method, path, body, Keyword.put(opts, :repo, __MODULE__))
      end

      @doc "Runs a `GET` against this repo; see `c:Dowser.Repo.request/4`."
      @spec get(String.t(), keyword()) :: Dowser.Client.result()
      def get(path, opts \\ []), do: request(:get, path, nil, opts)

      @doc "Runs a `POST` against this repo; see `c:Dowser.Repo.request/4`."
      @spec post(String.t(), term(), keyword()) :: Dowser.Client.result()
      def post(path, body \\ nil, opts \\ []), do: request(:post, path, body, opts)

      @doc "Runs a `PUT` against this repo; see `c:Dowser.Repo.request/4`."
      @spec put(String.t(), term(), keyword()) :: Dowser.Client.result()
      def put(path, body \\ nil, opts \\ []), do: request(:put, path, body, opts)

      @doc "Runs a `PATCH` against this repo; see `c:Dowser.Repo.request/4`."
      @spec patch(String.t(), term(), keyword()) :: Dowser.Client.result()
      def patch(path, body \\ nil, opts \\ []), do: request(:patch, path, body, opts)

      @doc "Runs a `DELETE` against this repo; see `c:Dowser.Repo.request/4`."
      @spec delete(String.t(), term(), keyword()) :: Dowser.Client.result()
      def delete(path, body \\ nil, opts \\ []), do: request(:delete, path, body, opts)

      @doc "Runs a `HEAD` against this repo; see `c:Dowser.Repo.request/4`."
      @spec head(String.t(), keyword()) :: Dowser.Client.result()
      def head(path, opts \\ []), do: request(:head, path, nil, opts)

      defoverridable request: 4
    end
  end

  ## Public functions

  @doc """
  Starts `repo`: resolves its configuration (`opts` merged over
  `config :otp_app, repo`, then `c:init/2`), stores it, starts its `:httpc`
  profile and — with `verify: true` — checks the engine.

  Use `repo.start_link/1` or `repo` in a supervision tree rather than calling
  this directly.
  """
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(repo, opts \\ []) do
    GenServer.start_link(__MODULE__.Server, {repo, opts}, name: repo)
  end

  @doc """
  `repo`'s resolved configuration: the stored one when the repo is started,
  resolved on the spot (with `init(:runtime, config)`) otherwise.

  Raises an `ArgumentError` when the configuration is invalid — no
  `:endpoint`, or `c:init/2` returning something else than `{:ok, config}`.
  """
  @spec context(module()) :: Context.t()
  def context(repo) when is_atom(repo) do
    case :persistent_term.get(key(repo), nil) do
      %{context: context} ->
        context

      nil ->
        case resolve(repo, [], :runtime) do
          {:ok, context, _verify} ->
            context

          {:error, reason} ->
            raise ArgumentError, "cannot resolve repo #{inspect(repo)}: #{inspect(reason)}"
        end
    end
  end

  @doc "What `c:verify/1` found when `repo` started with `verify: true`, or `nil`."
  @spec engine(module()) :: term() | nil
  def engine(repo) when is_atom(repo) do
    case :persistent_term.get(key(repo), nil) do
      %{engine: engine} ->
        engine

      nil ->
        nil
    end
  end

  @doc """
  Whether `term` is a repo module: one defined with `use Dowser.Repo` (or a
  backend's `use ...Repo`).
  """
  @spec repo?(term()) :: boolean()
  def repo?(term) when is_atom(term) and not is_nil(term) do
    Code.ensure_loaded?(term) and function_exported?(term, :__otp_app__, 0)
  end

  def repo?(_term), do: false

  @doc """
  Runs a request against `repo`: through `repo.request/4` for a repo module —
  so a mock repo sees it — or straight through `Dowser.Client.request/4` for
  an ad-hoc one.
  """
  @spec request(t(), Dowser.Client.method(), String.t(), term(), keyword()) ::
          Dowser.Client.result()
  def request(repo, method, path, body, opts) do
    if repo?(repo) do
      repo.request(method, path, body, Keyword.delete(opts, :repo))
    else
      Dowser.Client.request(method, path, body, Keyword.put(opts, :repo, repo))
    end
  end

  ## Internal — shared with the server

  @doc false
  @spec resolve(module(), keyword(), :supervisor | :runtime) ::
          {:ok, Context.t(), boolean()} | {:error, term()} | :ignore
  def resolve(repo, opts, type) do
    config =
      repo.__otp_app__()
      |> Application.get_env(repo, [])
      |> Keyword.merge(opts)

    case init(repo, type, config) do
      {:ok, config} ->
        build(repo, config)

      :ignore ->
        :ignore

      other ->
        {:error, {:bad_init, other}}
    end
  end

  @doc false
  def key(repo), do: {__MODULE__, repo}

  defp init(repo, type, config) do
    if function_exported?(repo, :init, 2) do
      repo.init(type, config)
    else
      {:ok, config}
    end
  end

  defp build(repo, config) do
    if Keyword.has_key?(config, :endpoint) do
      context = config |> Keyword.put_new(:profile, repo) |> Context.new()

      {:ok, context, Keyword.get(config, :verify, false)}
    else
      {:error, :missing_endpoint}
    end
  end

  defmodule Server do
    @moduledoc false

    # The process behind a started repo: it resolves the configuration once,
    # publishes it, and holds nothing else. Stopping it unpublishes it, so the
    # repo goes back to resolving per request.

    use GenServer

    alias Dowser.Client.HTTP.Profile

    @impl true
    def init({repo, opts}) do
      Process.flag(:trap_exit, true)

      case Dowser.Repo.resolve(repo, opts, :supervisor) do
        {:ok, context, verify} ->
          with {:ok, _profile} <- Profile.ensure_started(context.profile, context.profile_opts),
               {:ok, engine} <- verify(repo, context, verify) do
            :persistent_term.put(Dowser.Repo.key(repo), %{context: context, engine: engine})

            {:ok, repo}
          else
            {:error, reason} ->
              {:stop, reason}
          end

        :ignore ->
          :ignore

        {:error, reason} ->
          {:stop, reason}
      end
    end

    @impl true
    def terminate(_reason, repo) do
      :persistent_term.erase(Dowser.Repo.key(repo))
    end

    defp verify(_repo, _context, false), do: {:ok, nil}

    defp verify(repo, context, true) do
      if function_exported?(repo, :verify, 1) do
        repo.verify(context)
      else
        {:ok, nil}
      end
    end
  end
end
