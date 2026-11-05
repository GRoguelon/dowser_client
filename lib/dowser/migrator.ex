defmodule Dowser.Migrator do
  @moduledoc """
  Runs the migrations (`Dowser.Migration`) of a repo, from Mix —
  `mix dowser.migrate`, `mix dowser.rollback` — or from a release, where Mix
  isn't available:

      defmodule MyApp.Release do
        def migrate do
          Application.ensure_all_started(:dowser_client)
          Dowser.Migrator.run(MyApp.Search, :up, all: true, reindex: true)
        end
      end

  ## Where migrations live

  In `priv/dowser/migrations/` of the repo's application, or in the
  `:migrations_path` the repo is configured with, relative to the
  application's directory:

      config :my_app, MyApp.Search, migrations_path: "priv/search/migrations"

  ## What a run does

  It takes the repo's migration lock — one migrator at a time — then plans
  the whole run before sending any change: each index's migrations are folded
  together, checked against the index's mapping, settings and version, so a
  migration that can't run fails with nothing changed (`Dowser.Migration.Error`).

  The migrations it runs are recorded in the `dowser_schema_migrations` index.

  An index that must be copied — a field modified, renamed or removed, a
  static setting — is copied into a new index only with `reindex: true`:

    1. writes to the index are blocked (`write_block: false` to skip it), so a
       document written during the copy can't be lost: the write fails
       instead, for the application to retry;
    2. the new index is created, and the documents copied into it — through
       the script of the migrations' field operations;
    3. the alias moves onto it;
    4. the old index stays, writes blocked, for a rollback to move the alias
       back — unless `delete_previous: true`.

  If the copy fails, it is undone: the new index deleted, the old one
  unblocked. If even that fails, or the node running it dies, the lock stays
  with what the copy had changed, and every run refuses to start until
  `recover/2` (`mix dowser.recover`) has undone it.

  ## Rolling back

  A rollback runs `down/0`, or `change/0` inverted. An index the rolled-back
  migrations had copied moves back onto its previous index when it still
  exists — no copy, but the documents written since the migration aren't in
  it. Otherwise it is copied again (`reindex: true`), the operations reverted:
  a removed field's values are lost.
  """

  alias Dowser.Migration
  alias Dowser.Migration.Command
  alias Dowser.Migration.Error
  alias Dowser.Migration.Planner
  alias Dowser.Migration.Runner

  @default_path "priv/dowser/migrations"

  @typedoc "A migration: its version, name and module (once loaded)."
  @type migration :: %{version: integer(), name: String.t(), module: module() | nil}

  @doc """
  Runs `repo`'s pending migrations (`:up`) or rolls back the last ones
  (`:down`), returning the versions it ran.

  Options:

    * `:all` — every pending migration (the default up), or every one run
      (down).
    * `:step` — the next/last `n` (down defaults to `step: 1`).
    * `:to` — up to and including that version (up), down to and including it
      (down).
    * `:reindex` — allow copying indices (default `false`): without it, a
      migration needing a copy aborts the run before it changes anything.
    * `:write_block` — block writes to an index while it is copied (default
      `true`).
    * `:delete_previous` — delete the index a copy replaced (default `false`).
    * `:poll_interval` — how often a copy's progress is checked, in
      milliseconds (default `1000`).
    * `:log` — `false` to log nothing.
    * `:migrations_path` — where the migration files are.
    * `:migrations` — the migrations themselves, as `{version, module}`,
      rather than files.

  Raises a `Dowser.Migration.Error` when the run can't be planned or a step
  fails, a `Dowser.Migration.IrreversibleError` when a rollback can't be.
  """
  @spec run(Dowser.Repo.t(), :up | :down, keyword()) :: [integer()]
  def run(repo, direction, opts \\ []) when direction in [:up, :down] do
    adapter = adapter!(repo, opts)

    check!(adapter.ensure_tracking(repo), "creating the migrations' tracking index")
    lock!(repo, adapter)

    {result, keep_lock?} =
      try do
        execute(repo, adapter, direction, opts)
      rescue
        exception ->
          _ = adapter.unlock(repo)
          reraise exception, __STACKTRACE__
      end

    unless keep_lock?, do: check!(adapter.unlock(repo), "releasing the migration lock")

    case result do
      {:ok, versions} ->
        versions

      {:error, exception} ->
        raise exception
    end
  end

  defp execute(repo, adapter, direction, opts) do
    case prepare(repo, adapter, direction, opts) do
      {[], _plan} ->
        {{:ok, []}, false}

      {migrations, plan} ->
        case Runner.execute(plan, repo, adapter, opts) do
          :ok ->
            {{:ok, Enum.map(migrations, & &1.version)}, false}

          {:error, exception, keep_lock?} ->
            {{:error, exception}, keep_lock?}
        end
    end
  end

  @doc """
  Plans a run as `run/3` would — same options — without changing anything or
  taking the lock: the migrations it would run, and the requests it would
  send. `format_plan/1` prints them.
  """
  @spec plan(Dowser.Repo.t(), :up | :down, keyword()) :: {[migration()], Planner.plan()}
  def plan(repo, direction, opts \\ []) when direction in [:up, :down] do
    prepare(repo, adapter!(repo, opts), direction, opts)
  end

  @doc "A plan from `plan/3` as text: each index, then the requests sent for it."
  @spec format_plan({[migration()], Planner.plan()}) :: String.t()
  def format_plan({[], _plan}), do: "Nothing to run.\n"

  def format_plan({migrations, plan}) do
    verb = if plan.direction == :up, do: "Migrate", else: "Roll back"

    header = Enum.map(migrations, &"#{verb} #{&1.version} (#{&1.name})\n")

    groups =
      plan.groups
      |> Enum.reject(&(&1.steps == []))
      |> Enum.map(fn group ->
        ["\n", group.index, ":\n", Enum.map(group.steps, &["  ", Planner.describe(&1), "\n"])]
      end)

    IO.iodata_to_binary([header | groups])
  end

  @doc """
  `repo`'s migrations — from its files and its records — with whether each
  has run: `{:up | :down, version, name}`, by version. A migration recorded
  without a file has the name `"** FILE NOT FOUND **"`.
  """
  @spec migrations(Dowser.Repo.t(), keyword()) :: [{:up | :down, integer(), String.t()}]
  def migrations(repo, opts \\ []) do
    adapter = adapter!(repo, opts)
    applied = applied!(repo, adapter) |> Map.new(&{&1.version, &1})
    available = available(repo, opts) |> Map.new(&{&1.version, &1})

    applied
    |> Map.merge(available)
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn version ->
      status = if Map.has_key?(applied, version), do: :up, else: :down

      name =
        case available do
          %{^version => %{name: name}} ->
            name

          _missing ->
            "** FILE NOT FOUND **"
        end

      {status, version, name}
    end)
  end

  @doc """
  Undoes what a run left behind when it stopped in the middle of copying an
  index — the node died, or undoing the failed copy failed — and releases the
  lock:

    * the alias hadn't moved: the new index is deleted, the old one
      unblocked; returns `{:ok, {:undone, index}}`;
    * the alias had moved: the copy is kept — as if the run had finished it,
      whose next run records the migrations; returns `{:ok, {:kept, index}}`.

  Returns `{:ok, :released}` for a lock with no copy in progress, `{:ok,
  :unlocked}` without a lock.
  """
  @spec recover(Dowser.Repo.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def recover(repo, opts \\ []) do
    adapter = adapter!(repo, opts)

    case adapter.get_lock(repo) do
      {:ok, nil} ->
        {:ok, :unlocked}

      {:ok, %{"state" => %{"phase" => "copy"} = state}} ->
        with {:ok, result} <- recover_copy(repo, adapter, state),
             :ok <- adapter.unlock(repo) do
          {:ok, result}
        end

      {:ok, _lock} ->
        with :ok <- adapter.unlock(repo), do: {:ok, :released}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recover_copy(repo, adapter, state) do
    %{"index" => index, "dest" => dest} = state

    with {:ok, indices} <- adapter.get_indices(repo, [dest]) do
      aliases = get_in(indices, [dest, "aliases"])

      cond do
        is_nil(aliases) ->
          undo_copy(repo, adapter, state, false)

        index in aliases ->
          {:ok, {:kept, index}}

        true ->
          undo_copy(repo, adapter, state, true)
      end
    end
  end

  defp undo_copy(repo, adapter, state, dest_exists?) do
    %{"index" => index, "source" => source, "dest" => dest} = state

    with :ok <- if(dest_exists?, do: adapter.delete_index(repo, dest), else: :ok),
         :ok <- if(state["blocked"], do: adapter.remove_write_block(repo, source), else: :ok) do
      {:ok, {:undone, index}}
    end
  end

  @doc """
  Where `repo`'s migration files are: its `:migrations_path`, or
  `priv/dowser/migrations`, in its application's directory.
  """
  @spec migrations_path(Dowser.Repo.t()) :: String.t()
  def migrations_path(repo) do
    module = repo_module(repo)
    otp_app = module.__otp_app__()

    path =
      otp_app |> Application.get_env(module, []) |> Keyword.get(:migrations_path, @default_path)

    Application.app_dir(otp_app, path)
  end

  ## Preparing a run

  defp prepare(repo, adapter, direction, opts) do
    applied = applied!(repo, adapter)
    available = available(repo, opts)
    selected = select(direction, available, applied, opts)

    migrations =
      Enum.map(selected, fn migration ->
        module = load!(migration)
        Map.merge(migration, %{module: module, commands: commands(module, direction, repo)})
      end)

    indices = indices(repo, adapter, migrations, applied)

    plan =
      Planner.plan(direction, migrations,
        applied: applied,
        indices: indices,
        reindex: Keyword.get(opts, :reindex, false),
        delete_previous: Keyword.get(opts, :delete_previous, false),
        write_block: Keyword.get(opts, :write_block, true),
        dynamic?: &adapter.dynamic_setting?/1
      )

    {Enum.map(migrations, &Map.take(&1, [:version, :name, :module])), plan}
  end

  # The indices the migrations touch, then their siblings — named with the
  # separator of the index in place, or the one a migration creates it with.
  defp indices(repo, adapter, migrations, applied) do
    case migrations |> Enum.flat_map(&Planner.touched/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        what = "reading the indices #{Enum.join(names, ", ")}"
        current = repo |> adapter.get_indices(names) |> check!(what)

        patterns =
          names
          |> Enum.flat_map(fn name ->
            name
            |> Planner.separators(current, migrations, applied)
            |> Enum.map(&(name <> &1 <> "*"))
          end)
          |> Enum.uniq()

        siblings = repo |> adapter.get_indices(patterns) |> check!(what)

        Map.merge(current, siblings)
    end
  end

  defp select(:up, available, applied, opts) do
    done = MapSet.new(applied, & &1.version)
    pending = Enum.reject(available, &MapSet.member?(done, &1.version))

    limit(pending, opts, :all, &(&1.version <= &2))
  end

  defp select(:down, available, applied, opts) do
    files = Map.new(available, &{&1.version, &1})

    applied
    |> Enum.sort_by(& &1.version, :desc)
    |> Enum.map(fn record ->
      case Map.fetch(files, record.version) do
        {:ok, migration} ->
          migration

        :error ->
          %{version: record.version, name: record.name, file: nil, module: nil}
      end
    end)
    |> limit(opts, {:step, 1}, &(&1.version >= &2))
  end

  defp limit(migrations, opts, default, within_to) do
    cond do
      opts[:all] ->
        migrations

      step = opts[:step] ->
        Enum.take(migrations, step)

      to = opts[:to] ->
        Enum.take_while(migrations, &within_to.(&1, to))

      default == :all ->
        migrations

      true ->
        {:step, step} = default
        Enum.take(migrations, step)
    end
  end

  defp commands(module, direction, repo) do
    cond do
      direction == :up and function_exported?(module, :up, 0) ->
        Migration.__record__(repo, &module.up/0)

      direction == :down and function_exported?(module, :down, 0) ->
        Migration.__record__(repo, &module.down/0)

      function_exported?(module, :change, 0) ->
        commands = Migration.__record__(repo, &module.change/0)
        if direction == :up, do: commands, else: Command.invert(commands)

      true ->
        raise Error, "#{inspect(module)} defines neither change/0 nor #{direction}/0"
    end
  end

  ## Migrations

  defp available(repo, opts) do
    case Keyword.fetch(opts, :migrations) do
      {:ok, migrations} ->
        migrations
        |> Enum.map(fn {version, module} ->
          %{version: version, name: name_of(module), file: nil, module: module}
        end)
        |> sorted!()

      :error ->
        opts |> Keyword.get_lazy(:migrations_path, fn -> migrations_path(repo) end) |> files()
    end
  end

  defp files(path) do
    path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case Regex.run(~r/\A(\d+)_([a-z0-9_]+)\.exs\z/, Path.basename(file)) do
        [_match, version, name] ->
          [%{version: String.to_integer(version), name: name, file: file, module: nil}]

        nil ->
          []
      end
    end)
    |> sorted!()
  end

  defp sorted!(migrations) do
    migrations
    |> Enum.group_by(& &1.version)
    |> Enum.each(fn
      {_version, [_one]} ->
        :ok

      {version, _several} ->
        raise Error, "several migrations have the version #{version}"
    end)

    Enum.sort_by(migrations, & &1.version)
  end

  defp name_of(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp load!(%{module: module}) when not is_nil(module) do
    Code.ensure_loaded!(module)
  end

  defp load!(%{file: nil, version: version}) do
    raise Error, "migration #{version} was run, but its file isn't found"
  end

  defp load!(%{file: file}) do
    previous = Code.get_compiler_option(:ignore_module_conflict)

    modules =
      try do
        Code.put_compiler_option(:ignore_module_conflict, true)
        Code.compile_file(file)
      after
        Code.put_compiler_option(:ignore_module_conflict, previous)
      end

    case for {module, _binary} <- modules,
             function_exported?(module, :__migration__, 0),
             do: module do
      [module] ->
        module

      [] ->
        raise Error, "#{file} defines no migration (use Dowser.Migration)"

      _several ->
        raise Error, "#{file} defines several migrations"
    end
  end

  ## The cluster

  defp applied!(repo, adapter) do
    repo
    |> adapter.applied()
    |> check!("reading the migrations run")
    |> Enum.map(fn record ->
      %{
        version: to_integer(record["version"]),
        name: record["name"],
        indices: Map.get(record, "indices", []),
        dropped: Map.get(record, "dropped", []),
        separators: Map.get(record, "separators", %{})
      }
    end)
    |> Enum.sort_by(& &1.version)
  end

  defp to_integer(version) when is_integer(version), do: version
  defp to_integer(version) when is_binary(version), do: String.to_integer(version)

  defp lock!(repo, adapter) do
    lock = %{
      "owner" => Runner.owner(),
      "acquired_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "state" => nil
    }

    case adapter.lock(repo, lock) do
      :ok ->
        :ok

      {:error, {:locked, %{"state" => %{} = state} = held}} ->
        raise Error,
              "a migration run (#{held["owner"]}, #{held["acquired_at"]}) stopped while " <>
                "copying #{state["index"]}: run mix dowser.recover (Dowser.Migrator.recover/2) first"

      {:error, {:locked, held}} ->
        raise Error,
              "another migration run holds the lock (#{held["owner"]}, since #{held["acquired_at"]}); " <>
                "if it isn't running any more, run mix dowser.recover"

      {:error, reason} ->
        error!(reason, "taking the migration lock")
    end
  end

  defp adapter!(repo, opts) do
    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} ->
        adapter

      :error ->
        module = repo_module(repo)
        loaded? = Code.ensure_loaded?(module)

        if loaded? and function_exported?(module, :__migration_adapter__, 0) do
          module.__migration_adapter__()
        else
          raise ArgumentError,
                "#{inspect(module)} has no migration adapter: define it with a backend's " <>
                  "`use Dowser.OpenSearch.Repo` or `use Dowser.Elasticsearch.Repo`"
        end
    end
  end

  defp repo_module({module, _name}) when is_atom(module), do: module
  defp repo_module(module) when is_atom(module), do: module

  defp check!(:ok, _what), do: :ok
  defp check!({:ok, result}, _what), do: result

  defp check!({:error, reason}, what), do: error!(reason, what)

  @spec error!(term(), String.t()) :: no_return()
  defp error!(reason, what) do
    raise Error, "#{what} failed: #{Runner.format(reason)}"
  end
end
