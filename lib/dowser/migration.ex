defmodule Dowser.Migration do
  @moduledoc """
  A migration changes the indices of a repo, the way an `Ecto.Migration`
  changes the tables of a database.

  Migrations live in `priv/dowser/migrations/` (see `Dowser.Migrator` for
  another place), one per file, named after the UTC time they were generated
  at — `mix dowser.gen.migration create_events` writes
  `20261104120000_create_events.exs`. That timestamp is the migration's
  **version**.

      defmodule MyApp.Search.Migrations.CreateEvents do
        use Dowser.Migration

        def change do
          create_index "events", %{
            settings: %{number_of_shards: 3, number_of_replicas: replicas()},
            mappings: %{
              dynamic: :strict,
              properties: %{
                client_id: %{type: :keyword},
                body: %{type: :text},
                comments: %{type: :nested, properties: %{body: %{type: :text}}}
              }
            }
          }
        end

        # No replicas on a development machine's single node.
        defp replicas do
          if Application.get_env(:my_app, :env) == :dev, do: 0, else: 1
        end
      end

  `mix dowser.migrate` runs the migrations not run yet, `mix dowser.rollback`
  reverts the last one.

  ## Indices are aliases

  The name a migration gives — `"events"` — is always an alias. The index
  behind it is named after the version that created it, `events_20261104120000`,
  and its mapping records the version that last changed it in
  `_meta.dowser_version`. A change the cluster can't make in place — a field
  removed, renamed or retyped, a static setting — copies the documents into a
  new index (`events_<version>`) and moves the alias onto it.

  The separator between the name and the version is `_` unless the index is
  created with another — `create_index "events", body, separator: "-"` gives
  `events-20261104120000`. It is the index's own: every later copy of it, and
  the index a rollback recreates, uses it too.

  ## Operations

  The bodies are what the engine takes — the closest form to the final JSON —
  with atom or string keys. A migration is frozen history: give literal maps,
  or functions defined in the migration itself, rather than the application's
  own modules, which keep changing after the migration is written.

    * `create_index/2` — creates the index behind the alias.
    * `drop_index/2` — deletes it.
    * `alter_index/2,3` — changes its fields and settings, with `add/3`,
      `modify/3`, `rename/2`, `remove/2`, `set/3`, `unset/2` and `script/2` in
      its block.

  ## Functions

  Everything in a migration runs when the migration runs, not when it
  compiles: any value can come from a function, so a migration can differ from
  one cluster to another — locally and in production, from one repo or tenant
  to the next. The function can depend on the repo being migrated — `repo/0`
  returns it — or on your configuration. Don't use `Mix.env/0`: it doesn't
  exist in a release; record the environment in your configuration instead
  (`config :my_app, env: config_env()`).

  ## `change`, `up` and `down`

  `change/0` describes the migration forward, and is reverted by running its
  operations backwards, each one inverted. An operation that can't be inverted
  without more information — removing a field without its definition, a
  setting without `from:` — makes the rollback fail before anything is
  changed, with a `Dowser.Migration.IrreversibleError`.

  Or define `up/0` and `down/0`; they are used as they are.

  ## Copying documents

  When an index is copied, each operation changing documents — `rename/2`,
  `remove/2`, `add/3` with a `:default` — becomes a step of one painless
  script that dowser ships: the field names and values travel as the script's
  parameters, never as script source. It walks each document's `_source` as
  stored: a field inside a list of objects is changed in every object, at any
  depth, a missing or `null` parent is skipped, and a field stored with a
  dotted name (`"address.zip": ...`) is found too. `script/2` adds your own
  painless code between those steps.
  """

  @commands {__MODULE__, :commands}
  @alter {__MODULE__, :alter}
  @repo {__MODULE__, :repo}

  @doc "The migration forward; reverted by inverting its operations."
  @callback change() :: term()

  @doc "The migration forward."
  @callback up() :: term()

  @doc "The migration backward."
  @callback down() :: term()

  @optional_callbacks change: 0, up: 0, down: 0

  @typedoc """
  A field: its name, or the path to it through `object` and `nested` fields
  (`[:address, :zip]`).
  """
  @type field :: atom() | String.t() | [atom() | String.t()]

  @typedoc """
  A setting, relative to `index` (`:number_of_replicas`, or
  `[:analysis, :analyzer, :folded]`); a leading `:index` is accepted.
  """
  @type setting :: atom() | String.t() | [atom() | String.t()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Dowser.Migration

      import Dowser.Migration

      @doc false
      def __migration__, do: :ok
    end
  end

  ## Index commands

  @doc """
  Creates the index behind the alias `name`, from `body` — the body of the
  engine's create-index request (`settings`, `mappings`, `aliases`).

      create_index "events", %{
        settings: %{number_of_shards: 3},
        mappings: %{dynamic: :strict, properties: %{title: %{type: :text}}}
      }

  The index is named `<name><separator><version>`; its mapping's `_meta` gets
  `dowser_version`. Reverted by `drop_index/2`.

  Options:

    * `:separator` — between the name and the version (default `"_"`), e.g.
      `"-"` for `events-20261104120000`. It can't hold digits, uppercase
      letters, or a character index names don't allow. Every later copy of the
      index keeps it.
  """
  @spec create_index(String.t() | atom(), map(), keyword()) :: :ok
  def create_index(name, %{} = body, opts \\ []) do
    push(
      {:create_index, name(name), stringify(body),
       Keyword.take(validate_create!(opts), [:separator])}
    )
  end

  defp validate_create!(opts) do
    case Keyword.fetch(opts, :separator) do
      {:ok, separator} when is_binary(separator) ->
        unless separator =~ ~r/\A[^0-9A-Z\\\/*?"<>|\s,#:]+\z/u do
          raise ArgumentError,
                "a separator can't hold digits, uppercase letters, whitespace or any of " <>
                  ~S(\ / * ? " < > | , # :) <> ", got: #{inspect(separator)}"
        end

        opts

      {:ok, separator} ->
        raise ArgumentError, "a separator is a string, got: #{inspect(separator)}"

      :error ->
        opts
    end
  end

  @doc """
  Deletes the index behind the alias `name`.

  In `change/0`, give the index's `body` — as `create_index/2` takes it — to
  make it reversible: a rollback creates the index again, empty.
  """
  @spec drop_index(String.t() | atom(), map() | nil) :: :ok
  def drop_index(name, body \\ nil) when is_map(body) or is_nil(body) do
    push({:drop_index, name(name), body && stringify(body)})
  end

  @doc """
  Changes the index behind the alias `name` with the operations in its block.

      alter_index "events" do
        add :status, %{type: :keyword}, default: "active"
        rename [:comments, :body], :content
        remove :legacy, %{type: :long}
        set :number_of_replicas, 2, from: 1
      end

  `from:` names the version the index must be at — the migration that last
  changed it. Without it, the migrator works it out from the migrations it
  has run.

  Operations the engine applies in place — a field added without a default, a
  dynamic setting — run on the live index. Any other — a field modified,
  renamed, removed, added with a default, a static setting, a script — needs
  the documents copied into a new index, which only happens when the migrator
  is told to (`mix dowser.migrate --reindex`).
  """
  defmacro alter_index(name, do: block) do
    alter(name, [], block)
  end

  defmacro alter_index(name, opts, do: block) do
    alter(name, opts, block)
  end

  defp alter(name, opts, block) do
    quote do
      Dowser.Migration.__begin_alter__(unquote(name), unquote(opts))
      unquote(block)
      Dowser.Migration.__end_alter__()
    end
  end

  ## Field operations

  @doc """
  Adds a field, given its mapping `definition`.

      add :status, %{type: :keyword}
      add [:address, :zip], %{type: :keyword}

  Its parent must exist. Added to the live index, unless `default:` is given:
  then, the documents are copied and every object holding the field's parent
  gets `default` where the field is missing. Reverted by removing it.
  """
  @spec add(field(), map(), keyword()) :: :ok
  def add(field, %{} = definition, opts \\ []) do
    push_op({:add, path(field), stringify(definition), Keyword.fetch(opts, :default)})
  end

  @doc """
  Changes a field's mapping `definition`; the documents are copied, so the
  engine parses them again with the new one.

      modify :group_id, %{type: :keyword}, from: %{type: :keyword, ignore_above: 256}

  `from:` is the definition it has: checked against the index's mapping before
  anything changes, and needed to revert it.
  """
  @spec modify(field(), map(), keyword()) :: :ok
  def modify(field, %{} = definition, opts \\ []) do
    push_op({:modify, path(field), stringify(definition), fetch_definition(opts)})
  end

  @doc """
  Renames a field, keeping it under the same parent; the documents are copied,
  their value moved to the new name.

      rename :body, :content
      rename [:comments, :body], :content

  A document already holding a field under the new name fails the copy rather
  than lose one of the two values. Reverted by renaming it back.
  """
  @spec rename(field(), atom() | String.t()) :: :ok
  def rename(field, to) when is_atom(to) or is_binary(to) do
    push_op({:rename, path(field), to_string(to)})
  end

  @doc """
  Removes a field; the documents are copied without it.

      remove :legacy, %{type: :long}

  Its `definition` is checked against the index's mapping before anything
  changes, and makes it reversible — a rollback maps the field again, but
  can't bring its values back.
  """
  @spec remove(field(), map() | nil) :: :ok
  def remove(field, definition \\ nil) when is_map(definition) or is_nil(definition) do
    push_op({:remove, path(field), definition && stringify(definition)})
  end

  ## Setting operations

  @doc """
  Sets a setting to `value` — a map for a group of settings.

      set :number_of_replicas, 2, from: 1
      set [:analysis, :analyzer, :folded], %{tokenizer: :standard, filter: [:asciifolding]}, from: nil

  A dynamic setting changes on the live index; a static one needs the
  documents copied.

  `from:` is the value it has — `nil` for none — checked against the index
  before anything changes, the migration aborting when they differ; and
  needed to revert it.
  """
  @spec set(setting(), term(), keyword()) :: :ok
  def set(setting, value, opts \\ []) do
    push_op({:set, setting(setting), stringify(value), fetch_value(opts)})
  end

  @doc """
  Resets a setting to the engine's default.

      unset :max_result_window, from: 50_000

  `from:` is the value it has, as for `set/3`.
  """
  @spec unset(setting(), keyword()) :: :ok
  def unset(setting, opts \\ []) do
    push_op({:unset, setting(setting), fetch_value(opts)})
  end

  ## Scripts

  @doc """
  Runs painless `source` on each document while it is copied — for what the
  other operations don't do, a value converted, a field computed.

      script "ctx._source.amount = ctx._source.amount / 100.0",
        reverse: "ctx._source.amount = (long) (ctx._source.amount * 100)"

  Options:

    * `:params` — the script's parameters, as `params.<name>`; shared by all
      the scripts of one copy.
    * `:reverse` — the painless source reverting it; without it, the script
      makes `change/0` irreversible.
  """
  @spec script(String.t(), keyword()) :: :ok
  def script(source, opts \\ []) when is_binary(source) do
    params = opts |> Keyword.get(:params, %{}) |> stringify()

    push_op({:script, source, params, Keyword.fetch(opts, :reverse)})
  end

  ## Context

  @doc """
  The repo being migrated — the module, or `{module, name}` for a dynamic
  instance. Only available while a migration runs.
  """
  @spec repo() :: Dowser.Repo.t()
  def repo do
    case Process.get(@repo) do
      nil ->
        raise ArgumentError, "repo/0 is only available while a migration runs"

      repo ->
        repo
    end
  end

  ## Internal

  @doc false
  # Runs `fun` — a migration's `change/0`, `up/0` or `down/0` — for `repo`,
  # returning the commands it gave, in order.
  @spec __record__(Dowser.Repo.t(), (-> term())) :: [tuple()]
  def __record__(repo, fun) do
    Process.put(@repo, repo)
    Process.put(@commands, [])

    try do
      _ = fun.()

      if Process.get(@alter) do
        raise ArgumentError, "alter_index/2 didn't finish"
      end

      @commands |> Process.get() |> Enum.reverse()
    after
      Process.delete(@repo)
      Process.delete(@commands)
      Process.delete(@alter)
    end
  end

  @doc false
  def __begin_alter__(name, opts) do
    if Process.get(@alter) do
      raise ArgumentError, "alter_index/2 can't be nested"
    end

    from = Keyword.get(opts, :from)

    unless is_nil(from) or is_integer(from) do
      raise ArgumentError, "alter_index/2 :from is a migration version, got: #{inspect(from)}"
    end

    Process.put(@alter, {name(name), from, []})
    :ok
  end

  @doc false
  def __end_alter__ do
    {name, from, ops} = Process.delete(@alter)

    push({:alter_index, name, from, Enum.reverse(ops)})
  end

  defp push(command) do
    if Process.get(@alter) do
      raise ArgumentError, "#{elem(command, 0)} can't be used inside alter_index/2"
    end

    case Process.get(@commands) do
      nil ->
        raise ArgumentError, "#{elem(command, 0)} is only available while a migration runs"

      commands ->
        Process.put(@commands, [command | commands])
        :ok
    end
  end

  defp push_op(op) do
    case Process.get(@alter) do
      {name, from, ops} ->
        Process.put(@alter, {name, from, [op | ops]})
        :ok

      nil ->
        raise ArgumentError, "#{elem(op, 0)} is only available inside alter_index/2"
    end
  end

  defp name(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp name(name) when is_binary(name) and name != "", do: name

  defp name(name) do
    raise ArgumentError, "an index name is a string or an atom, got: #{inspect(name)}"
  end

  defp path(field) when is_list(field) and field != [], do: Enum.map(field, &segment/1)
  defp path(field), do: [segment(field)]

  defp setting(setting) do
    case setting |> path() |> Enum.flat_map(&String.split(&1, ".")) do
      ["index" | [_ | _] = rest] ->
        rest

      path ->
        path
    end
  end

  defp segment(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp segment(name) when is_binary(name) and name != "", do: name

  defp segment(name) do
    raise ArgumentError, "a field or setting name is a string or an atom, got: #{inspect(name)}"
  end

  defp fetch_definition(opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, %{} = from} ->
        {:ok, stringify(from)}

      {:ok, other} ->
        raise ArgumentError, ":from is a field definition (a map), got: #{inspect(other)}"

      :error ->
        :error
    end
  end

  defp fetch_value(opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, from} ->
        {:ok, stringify(from)}

      :error ->
        :error
    end
  end

  @doc false
  # Keys to strings, atom values to strings — the JSON the engine sees, so
  # definitions compare with what it returns.
  @spec stringify(term()) :: term()
  def stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  def stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  def stringify(value) when is_boolean(value) or is_nil(value), do: value
  def stringify(value) when is_atom(value), do: Atom.to_string(value)
  def stringify(value), do: value
end
