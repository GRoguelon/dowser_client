defmodule Dowser.Repo do
  @moduledoc """
  A repo is one cluster an application talks to: where it is, how to
  authenticate, which connection pool to use and how to cast what it returns.

  A backend package builds on this module (`use Dowser.OpenSearch.Repo`,
  `use Dowser.Elasticsearch.Repo`); an application defines one module per kind
  of cluster:

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

  The fields of `Dowser.Repo.Config`, read from `config :otp_app, Repo`, merged
  with the options the repo is started with, then passed through `c:init/2`:

    * `:endpoint` (required), `:auth`, `:http_opts`, `:keys`, `:decoder`,
      `:encoder` — see `Dowser.Repo.Config`.
    * `:profile` — the `:httpc` profile; defaults to the name the repo was
      started under, so each repo — each instance of one — has its own
      connection pool. `:profile_opts` configures it.
    * `:verify` — check at startup that the endpoint is the engine the backend
      package expects, and fail to start otherwise (default `false`). A
      cluster that is down then stops the application from booting, which is
      why it is off by default.

  ## Static and dynamic repos

  A repo started as itself — `children = [MyApp.Search]` — is a **static**
  repo, configured from the application environment.

  The same module can also be started any number of times under other names,
  each with its own configuration — a cluster per tenant, say, or clusters
  only known at runtime. These are its **dynamic** instances:

      {:ok, _pid} = MyApp.Search.start_link(name: :tenant_a, endpoint: "https://a.internal:9200")
      {:ok, _pid} = MyApp.Search.start_link(name: :tenant_b, endpoint: "https://b.internal:9200")

  A dynamic instance starts from the static configuration and overrides it
  with its own options, `c:init/2` included (`config[:name]` is the instance's
  name). Start them under a `DynamicSupervisor` to add and remove them as
  tenants come and go.

  Which instance a request reaches is decided per process, as with
  `Ecto.Repo`:

      MyApp.Search.put_dynamic_repo(:tenant_a)
      Dowser.OpenSearch.Search.search(query, repo: MyApp.Search)   # → tenant_a

      MyApp.Search.with_dynamic_repo(:tenant_b, fn ->
        Dowser.OpenSearch.Search.search(query, repo: MyApp.Search) # → tenant_b
      end)

  or per call, without touching the process's choice, with `{repo, name}`:

      Dowser.OpenSearch.Search.search(query, repo: {MyApp.Search, :tenant_a})

  ## Started or not

  Started, a repo resolves its configuration once — `c:init/2` included — and
  keeps the result in `:persistent_term`, so a request only reads a term.

  A static repo that isn't started — a script, a Mix task, `iex -S mix`
  without the application — still works: its configuration is resolved on
  every request, with `c:init/2` called as `init(:runtime, config)`. A dynamic
  instance only exists once started.

  ## The HTTP verbs

  A repo exposes `request/4` and the verbs over it — `get/2`, `post/3`,
  `put/3`, `patch/3`, `delete/3` and `head/2` — taking a path relative to the
  endpoint, for any endpoint the API modules don't cover:

      MyApp.Search.post("/_plugins/_ml/models/_search", %{query: %{match_all: %{}}})

  They go to the process's dynamic repo, and return `Dowser.Client.request/4`'s
  result (`{:ok, %Dowser.Client.Response{}}` for any status).

  ## Testing

  `c:request/4` is the one place every request goes through, so a mock of this
  behaviour can stand in for a repo — `Mox.defmock(MyApp.SearchMock, for:
  Dowser.Repo)`, then `repo: MyApp.SearchMock`. It returns responses as
  `{:ok, %Dowser.Client.Response{status: 200, body: %{...}}}`, and stands in
  for the whole transport — encoding, decoding and casting included — so the
  body it returns is exactly what the caller gets. To exercise the casting
  too, stub the HTTP layer instead (`Dowser.Client.HTTP.Stub`), behind a real
  repo.
  """

  alias Dowser.Repo.Config

  ## Behaviour callbacks

  @doc """
  Adjusts the configuration before the repo uses it — the place for secrets
  that can't live in config files.

  `type` is `:supervisor` when the repo (or one of its instances) starts,
  `:runtime` when a static repo resolves its configuration without having been
  started. `config[:name]` is the name it is started under. Return
  `{:ok, config}` or `:ignore` (not started; `:supervisor` only).
  """
  @callback init(type :: :supervisor | :runtime, config :: keyword()) ::
              {:ok, keyword()} | :ignore

  @doc "Runs a request against this repo; see `Dowser.Client.request/4`."
  @callback request(Dowser.Client.method(), String.t(), term(), keyword()) ::
              Dowser.Client.result()

  @doc """
  Checks that `config` points at the engine the backend package expects,
  returning what it found (e.g. `{:opensearch, "2.15.0"}`).
  """
  @callback verify(Config.t()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks init: 2, verify: 1

  ## Typespecs

  @typedoc """
  What a `:repo` option takes: a repo module, one of its instances as
  `{repo, name}`, the attributes of an ad-hoc repo (`[endpoint: ...]`), or a
  resolved `Dowser.Repo.Config`.
  """
  @type t :: module() | {module(), atom()} | keyword() | map() | Config.t()

  ## The `use` macro

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      @behaviour Dowser.Repo

      @doc false
      def __otp_app__, do: unquote(otp_app)

      @doc "A child spec starting this repo, or one of its instances; see `Dowser.Repo`."
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        %{
          id: Keyword.get(opts, :name, __MODULE__),
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }
      end

      @doc """
      Starts this repo — or, with `name: name`, a dynamic instance of it —
      merging `opts` over its configuration; see `Dowser.Repo`.
      """
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        Dowser.Repo.start_link(__MODULE__, opts)
      end

      @doc """
      The configuration of the instance this process uses, as a
      `Dowser.Repo.Config`.
      """
      @spec config() :: Dowser.Repo.Config.t()
      def config do
        Dowser.Repo.config(__MODULE__)
      end

      @doc """
      What `verify/1` found when the instance this process uses started with
      `verify: true`, or `nil`.
      """
      @spec engine() :: term() | nil
      def engine do
        Dowser.Repo.engine(__MODULE__)
      end

      @doc """
      Makes the calling process use the instance started as `name` — the repo
      itself by default. Returns the instance it used before.
      """
      @spec put_dynamic_repo(atom()) :: atom()
      def put_dynamic_repo(name) when is_atom(name) do
        Dowser.Repo.put_dynamic_repo(__MODULE__, name)
      end

      @doc "The instance the calling process uses — the repo itself by default."
      @spec get_dynamic_repo() :: atom()
      def get_dynamic_repo do
        Dowser.Repo.get_dynamic_repo(__MODULE__)
      end

      @doc """
      Runs `fun` with the calling process using the instance started as `name`,
      then restores the one it used before.
      """
      @spec with_dynamic_repo(atom(), (-> result)) :: result when result: term()
      def with_dynamic_repo(name, fun) when is_atom(name) and is_function(fun, 0) do
        Dowser.Repo.with_dynamic_repo(__MODULE__, name, fun)
      end

      @impl Dowser.Repo
      def request(method, path, body \\ nil, opts \\ []) do
        repo = {__MODULE__, get_dynamic_repo()}

        Dowser.Client.request(method, path, body, Keyword.put(opts, :repo, repo))
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
  Starts `repo`, or with `name: name` a dynamic instance of it: resolves its
  configuration (`opts` merged over `config :otp_app, repo`, then
  `c:init/2`), stores it under the instance's name, starts its `:httpc`
  profile and — with `verify: true` — checks the engine.

  Use `repo.start_link/1` or `repo` in a supervision tree rather than calling
  this directly.
  """
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(repo, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, repo)

    GenServer.start_link(__MODULE__.Server, {repo, name, opts}, name: name)
  end

  @doc """
  The configuration of a repo instance: of `repo`'s instance the calling
  process uses (see `put_dynamic_repo/2`), or of `{repo, name}`.

  A static repo that isn't started has its configuration resolved on the spot,
  with `init(:runtime, config)`. Raises an `ArgumentError` when it can't be — no
  `:endpoint`, `c:init/2` returning something else than `{:ok, config}` — or
  when a dynamic instance isn't started.
  """
  @spec config(module() | {module(), atom()}) :: Config.t()
  def config(repo) when is_atom(repo) do
    config({repo, get_dynamic_repo(repo)})
  end

  def config({repo, name}) when is_atom(repo) and is_atom(name) do
    case lookup(repo, name) do
      %{config: config} ->
        config

      nil when name == repo ->
        case resolve(repo, repo, [], :runtime) do
          {:ok, config, _verify} ->
            config

          other ->
            raise ArgumentError, "cannot resolve repo #{inspect(repo)}: #{inspect(other)}"
        end

      nil ->
        raise ArgumentError,
              "no instance #{inspect(name)} of repo #{inspect(repo)} is started; " <>
                "start it with #{inspect(repo)}.start_link(name: #{inspect(name)}, ...)"
    end
  end

  @doc """
  What `c:verify/1` found when a repo instance started with `verify: true`, or
  `nil` — for `repo`'s instance the calling process uses, or `{repo, name}`.
  """
  @spec engine(module() | {module(), atom()}) :: term() | nil
  def engine(repo) when is_atom(repo) do
    engine({repo, get_dynamic_repo(repo)})
  end

  def engine({repo, name}) when is_atom(repo) and is_atom(name) do
    case lookup(repo, name) do
      %{engine: engine} ->
        engine

      nil ->
        nil
    end
  end

  @doc """
  Makes the calling process use `repo`'s instance started as `name`, returning
  the one it used before. `name` is `repo` itself for the static repo.
  """
  @spec put_dynamic_repo(module(), atom()) :: atom()
  def put_dynamic_repo(repo, name) when is_atom(repo) and is_atom(name) do
    previous = get_dynamic_repo(repo)

    if name == repo do
      Process.delete(dynamic_key(repo))
    else
      Process.put(dynamic_key(repo), name)
    end

    previous
  end

  @doc "`repo`'s instance the calling process uses — `repo` itself by default."
  @spec get_dynamic_repo(module()) :: atom()
  def get_dynamic_repo(repo) when is_atom(repo) do
    Process.get(dynamic_key(repo), repo)
  end

  @doc """
  Runs `fun` with the calling process using `repo`'s instance `name`, then
  restores the instance it used before — even if `fun` raises.
  """
  @spec with_dynamic_repo(module(), atom(), (-> result)) :: result when result: term()
  def with_dynamic_repo(repo, name, fun) when is_atom(name) and is_function(fun, 0) do
    previous = put_dynamic_repo(repo, name)

    try do
      fun.()
    after
      put_dynamic_repo(repo, previous)
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
  Runs a request against `repo` — anything a `:repo` option takes: through the
  repo module's `request/4` for a repo or `{repo, name}` — so a mock repo sees
  it — or straight through `Dowser.Client.request/4` for an ad-hoc one.
  """
  @spec request(t(), Dowser.Client.method(), String.t(), term(), keyword()) ::
          Dowser.Client.result()
  def request(repo, method, path, body, opts) do
    opts = Keyword.delete(opts, :repo)

    case repo do
      {module, name} when is_atom(name) ->
        if repo?(module) do
          module.with_dynamic_repo(name, fn -> module.request(method, path, body, opts) end)
        else
          Dowser.Client.request(method, path, body, Keyword.put(opts, :repo, repo))
        end

      module when is_atom(module) ->
        if repo?(module) or implements_request?(module) do
          module.request(method, path, body, opts)
        else
          Dowser.Client.request(method, path, body, Keyword.put(opts, :repo, repo))
        end

      other ->
        Dowser.Client.request(method, path, body, Keyword.put(opts, :repo, other))
    end
  end

  # A module implementing `c:request/4` without `use Dowser.Repo` — a mock of
  # this behaviour, in a test. It answers requests; it has no configuration to
  # resolve, so casting configured on a repo doesn't apply through it.
  defp implements_request?(module) do
    not is_nil(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :request, 4)
  end

  ## Internal — shared with the server

  @doc false
  @spec resolve(module(), atom(), keyword(), :supervisor | :runtime) ::
          {:ok, Config.t(), boolean()} | {:error, term()} | :ignore
  def resolve(repo, name, opts, type) do
    config =
      repo.__otp_app__()
      |> Application.get_env(repo, [])
      |> Keyword.merge(opts)
      |> Keyword.put(:name, name)

    case init(repo, type, config) do
      {:ok, config} ->
        build(name, config)

      :ignore ->
        :ignore

      other ->
        {:error, {:bad_init, other}}
    end
  end

  @doc false
  def key(name), do: {__MODULE__, name}

  defp dynamic_key(repo), do: {__MODULE__, :dynamic, repo}

  # An instance's name is registered once, so a second repo module can't start
  # one under the same name; checking the repo still keeps `{other_repo, name}`
  # from answering with someone else's instance.
  defp lookup(repo, name) do
    case :persistent_term.get(key(name), nil) do
      %{repo: ^repo} = entry ->
        entry

      _other ->
        nil
    end
  end

  defp init(repo, type, config) do
    if function_exported?(repo, :init, 2) do
      repo.init(type, config)
    else
      {:ok, config}
    end
  end

  defp build(name, config) do
    if Keyword.has_key?(config, :endpoint) do
      config_struct = config |> Keyword.put_new(:profile, name) |> Config.new()

      {:ok, config_struct, Keyword.get(config, :verify, false)}
    else
      {:error, :missing_endpoint}
    end
  end

  defmodule Server do
    @moduledoc false

    # The process behind a started repo instance: it resolves the
    # configuration once, publishes it under the instance's name, and holds
    # nothing else. Stopping it unpublishes it — a static repo then goes back
    # to resolving per request, a dynamic instance ceases to exist.

    use GenServer

    alias Dowser.Client.HTTP.Profile

    @impl true
    def init({repo, name, opts}) do
      Process.flag(:trap_exit, true)

      case Dowser.Repo.resolve(repo, name, opts, :supervisor) do
        {:ok, config, verify} ->
          with {:ok, _profile} <- Profile.ensure_started(config.profile, config.profile_opts),
               {:ok, engine} <- verify(repo, config, verify) do
            :persistent_term.put(Dowser.Repo.key(name), %{
              repo: repo,
              config: config,
              engine: engine
            })

            {:ok, name}
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
    def terminate(_reason, name) do
      :persistent_term.erase(Dowser.Repo.key(name))
    end

    defp verify(_repo, _config, false), do: {:ok, nil}

    defp verify(repo, config, true) do
      if function_exported?(repo, :verify, 1) do
        repo.verify(config)
      else
        {:ok, nil}
      end
    end
  end
end
