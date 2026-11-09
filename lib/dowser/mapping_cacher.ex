defmodule Dowser.MappingCacher do
  @moduledoc """
  Per-node cache of index mappings, shared by the backend packages.

  A backend package defines its own cacher with `use`, which gives it its own
  process, its own ETS table and its own application environment:

      defmodule Dowser.OpenSearch.MappingCacher do
        use Dowser.MappingCacher, otp_app: :dowser_opensearch
      end

  The backend package doesn't start it: an application that casts against the
  cluster's mappings adds it to its own supervision tree, with its options:

      children = [MyApp.Search, {Dowser.OpenSearch.MappingCacher, ttl: :timer.minutes(10)}]

  Asked without having been started, it reports `{:not_started, cacher}` —
  which `Dowser.Codec` treats as a mapping it couldn't fetch.

  The functions below take that module as their first argument (`server`);
  the module `use` defines exposes them without it — `start_link/1`,
  `child_spec/1`, `key/2`, `get/2`, `lookup/2`, `fetch/2`, `put/3`,
  `invalidate/2` and `clear/0` — and implements `Dowser.Mapping` with
  `fetch_mapping/2`, which makes it a backend's default mapping source.

  A GenServer owns an ETS table; reads go straight to ETS (concurrent,
  lock-free), and only misses go through the GenServer — which de-duplicates
  concurrent fetches for the same key (single-flight).

  An entry is *fresh* for `:ttl`, then *stale* for `:max_stale`, then gone. A
  stale entry is still served, at once, while the GenServer refreshes it in
  the background: once a mapping has been fetched, no caller waits for it
  again, nor fails because a refresh did — see "When a fetch fails".

  Entries are keyed by `{endpoint, scope, index}`, so the same index reached
  through different contexts is cached separately, and each fetch honours its
  context. The *scope* is what distinguishes two contexts pointing at the same
  endpoint — see `key/2`.

  ## Options (`start_link/1`)

    * `:ttl` — how long a fetched entry is fresh, in **ms** (default 5 min).
    * `:max_stale` — how long, in ms, an entry past its `:ttl` may still be
      served while it is refreshed (default 1 hour). `:infinity` serves it
      until a refresh replaces it; `0` turns stale entries off, and an expired
      entry is a miss its caller waits on. The default rides out a cluster
      incident a dozen `:ttl`s long, and still bounds how out of date a
      mapping can get: past it, failing loudly beats casting against a
      mapping an hour old.
    * `:refresh_backoff` — how long, in ms, a stale entry whose refresh failed
      is left alone before a read refreshes it again (default 30 s), never
      past its `:max_stale`.
    * `:otp_app` — the prefix of the cacher's telemetry events. Defaults to
      the application given to `use` (`:dowser_client` for a cacher started
      without it). It only names the events: a static mapping is still read
      from the backend's application environment.
    * `:sweep_interval` — how often entries past `:max_stale` are actively
      purged, in ms (default 1 min). `nil`/`0` disables active sweeping; lazy
      expiration on read still applies.
    * `:fetch` — `(context, index -> {:ok, value} | {:error, reason})`, how a
      mapping is loaded on a miss. Defaults to a `Dowser.Client`
      `GET /{index}/_mapping` call.
    * `:eager` — preload at startup via `handle_continue/2`: `false` (default,
      lazy), a list of `{context, index}`, or a 0-arity fun returning one.

  ## Mappings that are never fetched

  A mapping given in the backend's application environment answers for its
  index without any request at all — and so can never fail to be fetched:

      config :dowser_opensearch,
        mappings: %{
          "posts" => %{
            "properties" => %{"published_at" => %{"type" => "date", "format" => "strict_date_time"}}
          }
        }

  It wins over the cache. Use it for an index whose mapping is pinned, and in
  test suites, where it makes casting behave as it does in production without
  a cluster to ask (`put/4` does the same through a running cacher).

  ## When a fetch fails

  `lookup/4` distinguishes "there is no mapping" from "the mapping could not be
  fetched"; `fetch/4` is the lenient read that folds both into `nil`. The
  difference matters because the second silently changes the *type* of what a
  caller gets back — see `Dowser.Codec`'s `:mapping_failure`.

  Only a fetch with nothing to fall back on can fail that way: the first one
  of a key, or one past its `:max_stale`. A *refresh* — the fetch of a stale
  entry — can't fail a caller, however slow or broken the cluster:

    * nobody waits on it: the stale value has already been returned;
    * when it fails, the stale value is kept, and so is replied to any caller
      that was waiting on the same key. It is then left alone for
      `:refresh_backoff` (30 seconds by default, never past its `:max_stale`)
      before a read refreshes it again, so that a struggling cluster isn't
      asked again on every read.

  A refresh that fails is still the cluster misbehaving, so it is reported.
  Where `:telemetry` is available, it emits `[otp_app, :mapping, :stale]`
  (`[:dowser_opensearch, :mapping, :stale]` for OpenSearch, unless `:otp_app`
  says otherwise), with
  `%{index: index, reason: reason}` as metadata; otherwise it logs a warning.

  `invalidate/3` drops an entry whatever its age, stale value included: the
  next read fetches it, and waits for it.
  """

  use GenServer

  require Logger

  alias Dowser.Repo.Config

  ## Module attributes

  @forever :timer.hours(24 * 365 * 100)
  @default_ttl :timer.minutes(5)
  @default_max_stale :timer.hours(1)
  @default_sweep :timer.minutes(1)
  @default_refresh_backoff :timer.seconds(30)
  @call_timeout :timer.seconds(15)

  # 128 bits: a birthday bound of 2^64 is far past anything a cache key needs,
  # and the key is copied on every lookup, so the other 16 bytes would be pure
  # overhead.
  @scope_bytes 16

  ## Typespecs

  @typedoc "A cache key: `{endpoint, scope, index}`."
  @type key :: {String.t(), binary() | nil, term()}

  ## The `use` facade

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      @behaviour Dowser.Mapping

      @doc """
      A child spec starting this cacher under its own name; see
      `Dowser.MappingCacher` for the options.
      """
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        Dowser.MappingCacher.child_spec(
          __MODULE__,
          Keyword.put_new(opts, :otp_app, unquote(otp_app))
        )
      end

      @doc "Starts this cacher; see `Dowser.MappingCacher` for the options."
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        Dowser.MappingCacher.start_link(
          __MODULE__,
          Keyword.put_new(opts, :otp_app, unquote(otp_app))
        )
      end

      @doc "The cache key for `{context, index}`; see `Dowser.MappingCacher.key/2`."
      @spec key(Dowser.Repo.Config.t(), term()) :: Dowser.MappingCacher.key()
      def key(context, index) do
        Dowser.MappingCacher.key(context, index)
      end

      @doc "Returns the mapping for `{context, index}`; see `Dowser.MappingCacher.get/3`."
      @spec get(Dowser.Repo.t(), term()) :: {:ok, term()} | {:error, term()}
      def get(context, index) do
        Dowser.MappingCacher.get(__MODULE__, context, index)
      end

      @doc """
      Returns the mapping for `{context, index}`, telling one that can't exist
      from one that couldn't be fetched; see `Dowser.MappingCacher.lookup/4`.
      """
      @spec lookup(Dowser.Repo.t(), term()) ::
              {:ok, map() | nil} | {:error, term()}
      def lookup(context, index) do
        Dowser.MappingCacher.lookup(__MODULE__, unquote(otp_app), context, index)
      end

      @doc """
      The mapping of `index` on `repo_config`'s cluster — `lookup/2` as the
      `Dowser.Mapping` behaviour, which makes this cacher the default mapping
      source.
      """
      @impl Dowser.Mapping
      def fetch_mapping(index, repo_config) do
        lookup(repo_config, index)
      end

      @doc "Like `lookup/2`, but `nil` on any failure; see `Dowser.MappingCacher.fetch/4`."
      @spec fetch(Dowser.Repo.t(), term()) :: map() | nil
      def fetch(context, index) do
        Dowser.MappingCacher.fetch(__MODULE__, unquote(otp_app), context, index)
      end

      @doc "Caches `mapping` for `index` directly; see `Dowser.MappingCacher.put/4`."
      @spec put(term(), map(), keyword()) :: :ok
      def put(index, mapping, opts \\ []) do
        Dowser.MappingCacher.put(__MODULE__, index, mapping, opts)
      end

      @doc "Invalidates a single `{context, index}` entry."
      @spec invalidate(Dowser.Repo.t(), term()) :: :ok
      def invalidate(context, index) do
        Dowser.MappingCacher.invalidate(__MODULE__, context, index)
      end

      @doc "Clears the whole cache."
      @spec clear() :: :ok
      def clear do
        Dowser.MappingCacher.clear(__MODULE__)
      end
    end
  end

  ## Client API

  @doc "A child spec starting the cacher named `server`."
  @spec child_spec(atom(), keyword()) :: Supervisor.child_spec()
  def child_spec(server, opts) do
    %{id: server, start: {__MODULE__, :start_link, [server, opts]}}
  end

  @doc "Starts the cacher named `server`, which also names its ETS table."
  @spec start_link(atom(), keyword()) :: GenServer.on_start()
  def start_link(server, opts \\ []) do
    GenServer.start_link(__MODULE__, {server, opts}, name: server)
  end

  @doc """
  The cache key for `{context, index}`: `{endpoint, scope, index}`.

  Two contexts pointing at the same endpoint do not necessarily see the same
  mapping — different credentials can mean field-level security hiding fields,
  or an alias resolving to a different concrete index — so the credentials are
  part of what identifies an entry.

  They are *hashed* into it rather than stored. A cache key lives in an ETS
  table for the lifetime of the entry, where any process can read it and a
  crash dump would carry it; `Dowser.Repo.Config` goes as far as redacting
  `:auth` from its own `Inspect`, and putting it in a table here would undo
  that.

  The hash is SHA-256, truncated to 128 bits. An application that builds
  contexts from end-user credentials makes the hashed value attacker-
  influenced, and a collision there would serve one tenant another's mapping —
  so the cheaper `:erlang.phash2/1` is the wrong tool: its default range is
  2^27, which a targeted collision search exhausts in seconds.

  `:http_opts` is hashed alongside `:auth`, since a credential can also arrive
  as a header and a proxy or TLS setting can change which cluster answers. The
  purely client-side fields (`:profile`, `:keys`, `:decoder`, `:encoder`) are
  not: they can't change what the backend returns. A plain unauthenticated
  context hashes to `nil`, so the common key stays readable.
  """
  @spec key(Config.t(), term()) :: key()
  def key(%Config{} = context, index), do: {context.endpoint, scope(context), index}

  @doc """
  Returns the mapping for `{context, index}` from `server`, fetching lazily on a
  miss.

  A stale entry is returned at once, and refreshed in the background.
  """
  @spec get(atom(), Dowser.Repo.t(), term()) :: {:ok, term()} | {:error, term()}
  def get(server, context, index) do
    with {:ok, resolved} <- Config.resolve(context) do
      key = key(resolved, index)

      # Hot path: read ETS directly, no GenServer involved — and none waited on
      # for a stale entry, whose refresh is a cast.
      case fresh_lookup(server, key) do
        {:fresh, value} ->
          {:ok, value}

        {:stale, value} ->
          GenServer.cast(server, {:refresh, key, resolved, index})
          {:ok, value}

        :miss ->
          GenServer.call(server, {:fetch, key, resolved, index}, @call_timeout)
      end
    end
  end

  @doc """
  Like `get/3`, but tells a mapping that *cannot exist* apart from one that
  *could not be fetched* — which `get/3` reports the same way, and which the
  caller must not: casting against no mapping is correct for the first and
  silently wrong for the second.

    * `{:ok, mapping}` — a static mapping (from `otp_app`'s environment), a
      cached one, or a freshly fetched one.
    * `{:ok, nil}` — there is no mapping to be had: no index named, or no
      repo to ask.
    * `{:error, {:not_started, server}}` — the cacher isn't running. A
      backend package doesn't start it: an application that casts against the
      cluster's mappings starts it in its supervision tree. A static mapping
      still answers without it.
    * `{:error, reason}` — the fetch failed. The mapping may well exist; this
      request just couldn't see it. `Dowser.Codec` turns this into a
      `Dowser.MappingError` by default, rather than casting nothing and handing
      back raw JSON values.

  A static mapping wins over the cache and is never fetched, so it cannot fail.
  """
  @spec lookup(atom(), atom(), Dowser.Repo.t(), term()) :: {:ok, map() | nil} | {:error, term()}
  def lookup(server, otp_app, context, index)

  def lookup(_server, _otp_app, nil, _index), do: {:ok, nil}
  def lookup(_server, _otp_app, _context, nil), do: {:ok, nil}

  def lookup(server, otp_app, context, index) do
    case static(otp_app, index) do
      nil ->
        cached(server, context, index)

      mapping ->
        {:ok, mapping}
    end
  end

  @doc """
  Like `lookup/4`, but returns the mapping directly, or `nil` when there is
  none to be had *or* the fetch failed.

  The lenient read: a mapping that can't be resolved degrades a cast to
  identity rather than failing the request.
  """
  @spec fetch(atom(), atom(), Dowser.Repo.t(), term()) :: map() | nil
  def fetch(server, otp_app, context, index) do
    case lookup(server, otp_app, context, index) do
      {:ok, mapping} ->
        mapping

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Caches `mapping` for `index` directly in `server`, without fetching anything.

  The seam tests use, so that casting behaves the way it does in production
  instead of degrading to identity for want of a cluster to ask:

      setup do
        Dowser.OpenSearch.MappingCacher.put("posts", %{"properties" => %{...}}, repo: MyApp.Search)
      end

  ## Options

    * `:repo` (required) — the repo the entry belongs to, as in `key/2`: a
      `Dowser.Repo` module or `[endpoint: ...]`. Raises an `ArgumentError`
      when it can't be resolved.
    * `:ttl` — entry lifetime in ms (default `:infinity`, unlike a fetched
      entry: an entry put by hand is not a cached answer that can go stale).
  """
  @spec put(atom(), term(), map(), keyword()) :: :ok
  def put(server, index, mapping, opts \\ []) when is_map(mapping) do
    if not running?(server) do
      raise "#{inspect(server)} is not running; start it before putting a mapping into it"
    end

    ttl = Keyword.get(opts, :ttl, :infinity)

    case Config.resolve(Keyword.get(opts, :repo)) do
      {:ok, context} ->
        GenServer.call(server, {:put, context, index, mapping, ttl})

      {:error, reason} ->
        raise ArgumentError,
              "cannot put a mapping without a repo to key it by: #{inspect(reason)}"
    end
  end

  @doc """
  Invalidates a single `{context, index}` entry of `server`, stale value
  included: the next read fetches it.
  """
  @spec invalidate(atom(), Dowser.Repo.t(), term()) :: :ok
  def invalidate(server, context, index) do
    case Config.resolve(context) do
      {:ok, config} ->
        GenServer.call(server, {:invalidate, config, index})

      # No repo to resolve, so nothing could have been cached under it.
      {:error, _reason} ->
        :ok
    end
  end

  @doc "Clears the whole cache of `server`."
  @spec clear(atom()) :: :ok
  def clear(server), do: GenServer.call(server, :clear)

  ## Server

  @impl GenServer
  def init({server, opts}) do
    ^server = :ets.new(server, [:named_table, :set, :protected, read_concurrency: true])

    state = %{
      table: server,
      otp_app: Keyword.get(opts, :otp_app, :dowser_client),
      ttl: to_native(Keyword.get(opts, :ttl, @default_ttl)),
      max_stale: to_native(Keyword.get(opts, :max_stale, @default_max_stale)),
      refresh_backoff: to_native(Keyword.get(opts, :refresh_backoff, @default_refresh_backoff)),
      sweep_interval: Keyword.get(opts, :sweep_interval, @default_sweep),
      fetch: Keyword.get(opts, :fetch, &default_fetch/2),
      eager: Keyword.get(opts, :eager, false),
      inflight: %{}
    }

    :ok = schedule_sweep(state.sweep_interval)
    {:ok, state, {:continue, :warm}}
  end

  # Eager preload — blocks startup until every configured mapping is loaded.
  @impl GenServer
  def handle_continue(:warm, state) do
    warm(state.eager, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:fetch, key, context, index}, from, state) do
    # Re-check under the GenServer: another caller may have filled it while we
    # were queued.
    case fresh_lookup(state.table, key) do
      {:fresh, value} ->
        {:reply, {:ok, value}, state}

      {:stale, value} ->
        {:reply, {:ok, value}, ensure_fetch(state, key, context, index)}

      :miss ->
        state =
          state
          |> ensure_fetch(key, context, index)
          |> add_waiter(key, from)

        {:noreply, state}
    end
  end

  # Both receive the repo already resolved: `put/4` and `invalidate/3` resolve
  # it in the caller's process, where a repo that can't be resolved is reported.
  def handle_call({:put, %Config{} = config, index, mapping, ttl}, _from, state) do
    # Never served stale: an entry put by hand isn't a cached answer to refresh.
    true = store(state.table, key(config, index), mapping, to_native(ttl), 0)

    {:reply, :ok, state}
  end

  def handle_call({:invalidate, %Config{} = config, index}, _from, state) do
    true = :ets.delete(state.table, key(config, index))

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  # A stale read: refresh the entry unless it already is, or no longer needs
  # it — it may have been refreshed, or invalidated, since.
  @impl GenServer
  def handle_cast({:refresh, key, context, index}, state) do
    case fresh_lookup(state.table, key) do
      {:stale, _value} ->
        {:noreply, ensure_fetch(state, key, context, index)}

      _fresh_or_gone ->
        {:noreply, state}
    end
  end

  # A single-flight fetch finished: store it, reply to every waiter.
  @impl GenServer
  def handle_info({:fetched, key, result}, state) do
    {waiters, inflight} = Map.pop(state.inflight, key, [])

    reply =
      case result do
        {:ok, value} ->
          store(state.table, key, value, state.ttl, state.max_stale)
          {:ok, value}

        {:error, reason} = error ->
          fall_back(state, key, reason, error)
      end

    Enum.each(waiters, &GenServer.reply(&1, reply))
    {:noreply, %{state | inflight: inflight}}
  end

  # Active expiration, of entries past their stale horizon.
  def handle_info(:sweep, state) do
    now = System.monotonic_time()
    :ets.select_delete(state.table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    :ok = schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  ## Keys

  defp scope(%Config{auth: nil, http_opts: []}), do: nil

  defp scope(%Config{} = context) do
    # `:deterministic` because `:http_opts` may hold a map (`:headers`), whose
    # ordinary encoding is not canonical — two equal contexts must not scope
    # differently.
    binary = :erlang.term_to_binary({context.auth, context.http_opts}, [:deterministic])

    <<scope::binary-size(@scope_bytes), _rest::binary>> = :crypto.hash(:sha256, binary)

    scope
  end

  ## Reads (run in the caller's process, straight off ETS)

  # A mapping given in the application environment is the answer, whatever the
  # cluster would say — no request, so nothing to fail.
  defp static(otp_app, index) do
    otp_app
    |> Application.get_env(:mappings, %{})
    |> Enum.find_value(fn {name, mapping} -> named?(name, index) && mapping end)
  end

  defp named?(name, index) when is_binary(index) or is_atom(index),
    do: to_string(name) == to_string(index)

  defp named?(name, index), do: name == index

  defp cached(server, context, index) do
    if running?(server) do
      get(server, context, index)
    else
      {:error, {:not_started, server}}
    end
  rescue
    exception ->
      {:error, exception}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # An application starts the cacher itself when it casts against the
  # cluster's mappings; one that is asked without having been started was
  # forgotten in a supervision tree, which `lookup/4` reports rather than
  # quietly casting nothing.
  defp running?(table), do: :ets.whereis(table) != :undefined

  defp fresh_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value, expires_at, stale_until}] ->
        # Lazy expiration: an entry past its stale horizon reads as a miss.
        now = System.monotonic_time()

        cond do
          expires_at > now -> {:fresh, value}
          stale_until > now -> {:stale, value}
          true -> :miss
        end

      [] ->
        :miss
    end
  end

  ## Single-flight

  defp add_waiter(state, key, from),
    do: %{state | inflight: Map.update!(state.inflight, key, &[from | &1])}

  # Fetch off the GenServer so it stays responsive to other keys' misses.
  # A key is fetched once at a time, whoever asks — a waiting caller or a
  # stale read, which waits on nothing — and its waiters are replied to when
  # it lands.
  defp ensure_fetch(state, key, context, index) do
    if Map.has_key?(state.inflight, key) do
      state
    else
      :ok = start_fetch(state.fetch, key, context, index)
      %{state | inflight: Map.put(state.inflight, key, [])}
    end
  end

  defp start_fetch(fetch, key, context, index) do
    parent = self()
    _pid = spawn(fn -> send(parent, {:fetched, key, safe_fetch(fetch, context, index)}) end)

    :ok
  end

  defp safe_fetch(fetch, context, index) do
    fetch.(context, index)
  rescue
    error ->
      {:error, error}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  # A failed fetch is an error only with nothing to fall back on. A stale value
  # is kept, and left alone for a while, so that a struggling cluster isn't
  # asked again on every read.
  defp fall_back(state, key, reason, error) do
    case fresh_lookup(state.table, key) do
      {:stale, value} ->
        [{^key, _value, _expires_at, stale_until}] = :ets.lookup(state.table, key)
        retry_at = min(System.monotonic_time() + state.refresh_backoff, stale_until)
        true = :ets.update_element(state.table, key, {3, retry_at})

        :ok = report_stale(state.otp_app, key, reason)
        {:ok, value}

      _fresh_or_gone ->
        error
    end
  end

  # `:telemetry` is an optional dependency, as in `Dowser.Codec`: the event
  # is emitted for the applications that have it, and the others get a log.
  if Code.ensure_loaded?(:telemetry) do
    defp report_stale(otp_app, {_endpoint, _scope, index}, reason) do
      metadata = %{index: index, reason: reason}
      :telemetry.execute([otp_app, :mapping, :stale], %{count: 1}, metadata)
    end
  else
    defp report_stale(_otp_app, {_endpoint, _scope, index}, reason) do
      Logger.warning(
        "MappingCacher refresh failed for #{inspect(index)}, serving its stale mapping: " <>
          inspect(reason)
      )
    end
  end

  ## Storage / TTL

  # Each entry carries both its deadlines — fresh until `expires_at`, stale
  # until `stale_until` — so that a read tells the three states apart from
  # the one row, in two integer comparisons.
  defp store(table, key, value, ttl, max_stale) do
    expires_at = System.monotonic_time() + ttl
    :ets.insert(table, {key, value, expires_at, expires_at + max_stale})
  end

  # An entry that never expires still carries a deadline, so the sweep and the
  # lazy check stay one comparison rather than two shapes.
  defp to_native(:infinity), do: to_native(@forever)
  defp to_native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp schedule_sweep(interval) when is_integer(interval) and interval > 0 do
    _timer = Process.send_after(self(), :sweep, interval)

    :ok
  end

  defp schedule_sweep(_disabled), do: :ok

  ## Eager warming

  defp warm(false, _state), do: :ok
  defp warm(fun, state) when is_function(fun, 0), do: warm(fun.(), state)

  defp warm(targets, state) when is_list(targets) do
    targets
    |> Task.async_stream(
      fn {context, index} -> {index, resolve_and_fetch(state.fetch, context, index)} end,
      max_concurrency: System.schedulers_online(),
      timeout: :timer.seconds(30),
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, {_index, {:ok, key, value}}} ->
        store(state.table, key, value, state.ttl, state.max_stale)

      {:ok, {index, {:error, reason}}} ->
        log_warm(index, reason)

      {:exit, reason} ->
        log_warm(:unknown, reason)
    end)
  end

  defp resolve_and_fetch(fetch, context, index) do
    with {:ok, resolved} <- Config.resolve(context),
         {:ok, value} <- fetch.(resolved, index) do
      {:ok, key(resolved, index), value}
    end
  end

  defp log_warm(index, reason),
    do: Logger.warning("MappingCacher warm failed for #{inspect(index)}: #{inspect(reason)}")

  ## Default fetch — GET /<index>/_mapping via Dowser.Client

  defp default_fetch(context, index) do
    case Dowser.Client.get("/#{index}/_mapping",
           repo: context,
           keys: :strings,
           decoder: &raw/2,
           format: :json
         ) do
      {:ok, %Dowser.Client.Response{status: 200, body: body}} ->
        {:ok, extract(body, index)}

      {:ok, %Dowser.Client.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # A mapping document is not a search result, so the context's own `:decoder`
  # has nothing to cast in it — and calling it here would recurse straight back
  # into this cacher. `:decoder` can't be unset per request (a `nil` falls back
  # to the context), so it is overridden with a pass-through instead.
  defp raw(body, _opts), do: body

  # body: %{"<index>" => %{"mappings" => %{...}}}
  defp extract(body, index) do
    case body do
      %{^index => %{"mappings" => mappings}} ->
        mappings

      %{} ->
        body |> Map.values() |> List.first(%{}) |> Map.get("mappings", %{})
    end
  end
end
