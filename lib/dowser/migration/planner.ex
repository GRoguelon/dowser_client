defmodule Dowser.Migration.Planner do
  @moduledoc false

  # Turns the commands of the migrations to run into the requests that run
  # them, against a snapshot of the cluster — without sending any: every check
  # (versions, fields, `from:` values, a copy allowed) happens here, so a
  # migration that can't run fails before anything changes.
  #
  # Each index is planned on its own, its migrations folded into one state:
  # several pending migrations altering one index copy it once. The plan is a
  # list of groups — one per index, its steps in order — and of the records
  # to write (or remove) once the groups they depend on are done.
  #
  # Index states: `:absent`, `{:present, version}`, or `{:unmanaged, index}`
  # for an index the migrator didn't create.

  alias Dowser.Migration.Command
  alias Dowser.Migration.Error
  alias Dowser.Migration.Properties
  alias Dowser.Migration.Script
  alias Dowser.Migration.Settings

  @default_separator "_"

  @type step ::
          {:create_index, String.t(), map()}
          | {:delete_index, String.t()}
          | {:put_mapping, String.t(), map()}
          | {:put_settings, String.t(), map()}
          | {:add_write_block, String.t()}
          | {:remove_write_block, String.t()}
          | {:reindex, String.t(), String.t(), map() | nil}
          | {:swap_alias, String.t(), String.t(), String.t()}

  @type group :: %{
          index: String.t(),
          steps: [step()],
          copy: %{source: String.t(), dest: String.t(), blocked: boolean()} | nil
        }

  @type plan :: %{
          direction: :up | :down,
          groups: [group()],
          records: [{integer(), {:record, map()} | {:unrecord, integer()}}]
        }

  @doc """
  Plans running `migrations` (`%{version, name, commands}`, in the order they
  run — commands already inverted for a rollback) in `direction`.

    * `:applied` — the records of the migrations run so far.
    * `:indices` — `Adapter.get_indices/2` for every index the migrations
      touch, and its siblings (`<name><separator>*`, see `separators/3`).
    * `:reindex`, `:delete_previous`, `:write_block` — the run's options.
    * `:dynamic?` — whether a setting is dynamic.
  """
  @spec plan(:up | :down, [map()], keyword()) :: plan()
  def plan(direction, migrations, opts) do
    applied = opts |> Keyword.fetch!(:applied) |> Enum.sort_by(& &1.version)
    indices = Keyword.fetch!(opts, :indices)
    names = migrations |> Enum.flat_map(&touched/1) |> Enum.uniq()

    taken = indices |> Map.keys() |> MapSet.new()

    {groups, _taken} =
      Enum.map_reduce(names, taken, fn name, taken ->
        plan_index(direction, name, migrations, applied, indices, taken, opts)
      end)

    positions = names |> Enum.with_index() |> Map.new()

    separators = Map.new(names, &{&1, known_separator(&1, indices, applied)})

    {records, _separators} =
      Enum.map_reduce(migrations, separators, fn migration, separators ->
        position = migration |> touched() |> Enum.map(&positions[&1]) |> Enum.max(fn -> -1 end)
        separators = created_separators(migration, separators)

        {{position, record(direction, migration, separators)}, separators}
      end)

    %{direction: direction, groups: groups, records: records}
  end

  @doc "The indices a migration touches, in order."
  @spec touched(map()) :: [String.t()]
  def touched(%{commands: commands}) do
    commands |> Enum.map(&Command.index/1) |> Enum.uniq()
  end

  # The record keeps each index's separator, for a rollback to recreate an
  # index this run — or a later one — drops with the name it had.
  defp record(:up, migration, separators) do
    {:record,
     %{
       "version" => migration.version,
       "name" => migration.name,
       "indices" => touched(migration),
       "dropped" => dropped(migration),
       "separators" => Map.take(separators, touched(migration))
     }}
  end

  defp record(:down, migration, _separators), do: {:unrecord, migration.version}

  # The separators once `migration` has run: those it creates indices with.
  defp created_separators(%{commands: commands}, separators) do
    Enum.reduce(commands, separators, fn
      {:create_index, name, _body, opts}, separators ->
        Map.put(separators, name, opts[:separator] || separators[name] || @default_separator)

      _command, separators ->
        separators
    end)
  end

  # The separator of the index in place, or else the one recorded with the
  # last migration that touched it.
  defp known_separator(name, indices, applied) do
    in_place =
      name
      |> current(indices)
      |> Enum.find_value(fn {physical, _index} -> separator(name, physical) end)

    in_place || recorded_separator(name, applied)
  end

  defp recorded_separator(name, applied) do
    applied
    |> Enum.map(&Map.get(&1, :separators, %{}))
    |> Enum.filter(&is_map_key(&1, name))
    |> List.last(%{})
    |> Map.get(name)
  end

  # The indices a migration leaves absent: its last command on them drops them.
  defp dropped(%{commands: commands}) do
    commands
    |> Enum.group_by(&Command.index/1)
    |> Enum.filter(fn {_name, commands} -> match?({:drop_index, _, _}, List.last(commands)) end)
    |> Enum.map(fn {name, _commands} -> name end)
    |> Enum.sort()
  end

  ## One index

  defp plan_index(direction, name, migrations, applied, indices, taken, opts) do
    {actual, current, others, separator} = snapshot(name, indices)
    touching = Enum.filter(migrations, &(name in touched(&1)))
    states = states(direction, name, touching, applied)
    skip = skip(name, actual, states)

    sim =
      start(name, actual, current, others, taken, separator || recorded_separator(name, applied))

    sim =
      touching
      |> Enum.zip(tl(states))
      |> Enum.drop(skip)
      |> Enum.reduce(sim, fn {migration, state}, sim ->
        run_migration(sim, migration, state, opts)
      end)

    finish(sim, direction, opts)
  end

  # The state of the index before each of `touching` runs, then after the
  # last: up, the version of each migration (or absent, when it drops the
  # index); down, the version of the migration run before each one.
  defp states(:up, name, touching, applied) do
    start = applied |> Enum.filter(&(name in &1.indices)) |> List.last() |> after_record(name)

    [start | Enum.map(touching, &after_migration(&1, name))]
  end

  defp states(:down, name, touching, applied) do
    touched_applied = Enum.filter(applied, &(name in &1.indices))
    start = touched_applied |> List.last() |> after_record(name)

    previous =
      Enum.map(touching, fn migration ->
        touched_applied
        |> Enum.filter(&(&1.version < migration.version))
        |> List.last()
        |> after_record(name)
      end)

    [start | previous]
  end

  defp after_record(nil, _name), do: :absent

  defp after_record(record, name) do
    if name in record.dropped, do: :absent, else: {:present, record.version}
  end

  defp after_migration(migration, name) do
    if name in dropped(migration), do: :absent, else: {:present, migration.version}
  end

  # How many of the migrations the index has already been through: none
  # normally, more when a run stopped after changing it but before recording
  # the migrations. An index in none of the expected states was changed by
  # someone else.
  defp skip(name, actual, states) do
    case Enum.find_index(states, &(&1 == actual)) do
      nil ->
        fail(
          "#{name} is #{describe_state(actual)}, but the migrations expect it " <>
            "#{describe_state(hd(states))}; was it changed outside of them?"
        )

      skip ->
        skip
    end
  end

  defp describe_state(:absent), do: "absent"
  defp describe_state({:present, version}), do: "at version #{version}"
  defp describe_state({:unmanaged, index}), do: "an index (#{index}) the migrator didn't create"

  ## The snapshot

  # The index's state, the physical index behind it, its siblings (earlier
  # copies, named with the same separator) by version, and its separator.
  defp snapshot(name, indices) do
    case current(name, indices) do
      [] ->
        {:absent, nil, %{}, nil}

      [{^name, _index}] ->
        {{:unmanaged, name}, nil, %{}, nil}

      [{physical, index}] ->
        separator = separator(name, physical)

        others =
          for {other, index} <- indices,
              other != physical and sibling?(name, separator, other),
              into: %{} do
            {other, version(index)}
          end

        case version(index) do
          nil ->
            {{:unmanaged, physical}, nil, %{}, nil}

          version ->
            {{:present, version}, {physical, index}, others, separator}
        end

      several ->
        fail(
          "#{name} is an alias of several indices: #{Enum.map_join(several, ", ", &elem(&1, 0))}"
        )
    end
  end

  defp current(name, indices) do
    Enum.filter(indices, fn {physical, index} ->
      physical == name or name in Map.get(index, "aliases", [])
    end)
  end

  @doc """
  The separators the indices behind `name` can be named with — the one of the
  index in place, the one recorded for it, those its migrations create it
  with, `"_"` by default — for the migrator to fetch `<name><separator>*`.
  """
  @spec separators(String.t(), map(), [map()], [map()]) :: [String.t()]
  def separators(name, indices, migrations, applied) do
    current =
      for {physical, _index} <- current(name, indices),
          separator = separator(name, physical),
          do: separator

    created =
      for %{commands: commands} <- migrations,
          {:create_index, ^name, _body, opts} <- commands,
          separator = opts[:separator],
          do: separator

    recorded = List.wrap(recorded_separator(name, applied))

    Enum.uniq(current ++ recorded ++ created ++ [@default_separator])
  end

  # The separator `physical` was named with: what lies between `name` and the
  # version — `events-20261104120000` → `"-"` — or `nil`.
  defp separator(name, physical) do
    with true <- String.starts_with?(physical, name),
         [_match, separator] <-
           Regex.run(~r/\A(\D+?)\d+(?:\1\d+)?\z/, String.replace_prefix(physical, name, "")) do
      separator
    else
      _other ->
        nil
    end
  end

  defp sibling?(name, separator, physical) do
    with true <- String.starts_with?(physical, name <> separator) do
      suffix = String.replace_prefix(physical, name <> separator, "")
      Regex.match?(~r/\A\d+(?:#{Regex.escape(separator)}\d+)?\z/, suffix)
    end
  end

  defp version(index) do
    case get_in(index, ["mappings", "_meta", "dowser_version"]) do
      version when is_integer(version) ->
        version

      version when is_binary(version) ->
        String.to_integer(version)

      _other ->
        nil
    end
  end

  ## Simulation

  defp start(name, actual, current, others, taken, separator) do
    base = %{
      index: name,
      separator: separator,
      mode: :absent,
      physical: nil,
      version: nil,
      mappings: %{},
      settings: %{},
      base_settings: %{},
      extra: %{},
      added: [],
      data_ops: [],
      reasons: [],
      changed: false,
      steps: [],
      others: others,
      taken: taken,
      migration: nil
    }

    case {actual, current} do
      {{:present, version}, {physical, index}} ->
        settings = index |> Map.get("settings", %{}) |> Settings.flatten() |> Settings.copyable()

        %{
          base
          | mode: :existing,
            physical: physical,
            version: version,
            mappings: Map.get(index, "mappings", %{}),
            settings: settings,
            base_settings: settings
        }

      _other ->
        base
    end
  end

  defp run_migration(sim, migration, state, opts) do
    sim = %{sim | migration: migration}
    version = migration_version(state, migration)

    sim =
      migration.commands
      |> Enum.filter(&(Command.index(&1) == sim.index))
      |> Enum.reduce(sim, &run_command(&2, &1, version, opts))

    present = sim.mode != :absent

    if present != match?({:present, _version}, state) do
      fail(sim, "the migration leaves the index #{if present, do: "present", else: "absent"}")
    end

    sim
  end

  defp migration_version({:present, version}, _migration), do: version
  defp migration_version(:absent, migration), do: migration.version

  # The separator given, else the one of the index the run dropped or the
  # rollback recreates, else the default.
  defp run_command(%{mode: :absent} = sim, {:create_index, _name, body, opts}, version, _opts) do
    sim = %{sim | separator: opts[:separator] || sim.separator || @default_separator}
    physical = pick_name(sim, version)

    %{
      sim
      | mode: :new,
        physical: physical,
        version: version,
        mappings: body |> Map.get("mappings", %{}) |> put_meta(version),
        settings: body |> Map.get("settings") |> Settings.flatten(),
        extra: Map.drop(body, ["settings", "mappings"]),
        taken: MapSet.put(sim.taken, physical),
        changed: true
    }
  end

  defp run_command(sim, {:create_index, _name, _body, _create_opts}, _version, _opts) do
    fail(sim, "create_index: the index already exists")
  end

  defp run_command(%{mode: :absent} = sim, {command, _name, _body}, _version, _opts)
       when command in [:drop_index] do
    fail(sim, "#{command}: the index doesn't exist")
  end

  defp run_command(%{mode: :absent} = sim, {:alter_index, _name, _from, _ops}, _version, _opts) do
    fail(sim, "alter_index: the index doesn't exist")
  end

  defp run_command(sim, {:drop_index, _name, _body}, _version, _opts) do
    steps =
      case sim.mode do
        :existing ->
          [{:delete_index, sim.physical} | sim.steps]

        :new ->
          sim.steps
      end

    %{
      sim
      | mode: :absent,
        physical: nil,
        version: nil,
        mappings: %{},
        settings: %{},
        base_settings: %{},
        extra: %{},
        added: [],
        data_ops: [],
        reasons: [],
        changed: false,
        steps: steps
    }
  end

  defp run_command(sim, {:alter_index, _name, from, ops}, version, opts) do
    if from && from != sim.version do
      fail(sim, "alter_index from: #{from}, but the index is at version #{sim.version}")
    end

    sim = Enum.reduce(ops, sim, &run_op(&2, &1, opts))

    %{sim | version: version, mappings: put_meta(sim.mappings, version), changed: true}
  end

  ## Operations

  defp run_op(sim, {:add, path, definition, default}, _opts) do
    case Properties.fetch(sim.mappings, path) do
      {:ok, _field} ->
        fail(sim, "add #{Command.field(path)}: the field already exists")

      :error ->
        :ok
    end

    parent = Enum.drop(path, -1)

    unless Properties.object?(sim.mappings, parent) do
      fail(sim, "add #{Command.field(path)}: #{Command.field(parent)} isn't an object field")
    end

    sim = %{sim | mappings: Properties.put(sim.mappings, path, definition)}

    case default do
      {:ok, value} ->
        copy(sim, {:add, path, value}, "add #{Command.field(path)} with a default")

      :error ->
        %{sim | added: sim.added ++ [path]}
    end
  end

  defp run_op(sim, {:modify, path, definition, from}, _opts) do
    current = fetch_field!(sim, "modify", path)
    check_definition!(sim, "modify", path, current, from)

    sim
    |> Map.put(:mappings, Properties.put(sim.mappings, path, definition))
    |> copy(nil, "modify #{Command.field(path)}")
  end

  defp run_op(sim, {:rename, path, to}, _opts) do
    current = fetch_field!(sim, "rename", path)
    target = List.replace_at(path, -1, to)

    if Properties.fetch(sim.mappings, target) != :error do
      fail(sim, "rename #{Command.field(path)} to #{to}: #{Command.field(target)} already exists")
    end

    mappings = sim.mappings |> Properties.delete(path) |> Properties.put(target, current)

    sim
    |> Map.put(:mappings, mappings)
    |> copy({:rename, path, to}, "rename #{Command.field(path)}")
  end

  defp run_op(sim, {:remove, path, definition}, _opts) do
    current = fetch_field!(sim, "remove", path)

    check_definition!(
      sim,
      "remove",
      path,
      current,
      if(definition, do: {:ok, definition}, else: :error)
    )

    sim
    |> Map.put(:mappings, Properties.delete(sim.mappings, path))
    |> Map.put(:added, List.delete(sim.added, path))
    |> copy({:remove, path}, "remove #{Command.field(path)}")
  end

  defp run_op(sim, {:set, path, value, from}, opts) do
    key = Enum.join(path, ".")
    check_setting!(sim, "set", path, key, from)

    keys =
      case key |> Settings.at(value) |> Map.keys() do
        [] ->
          [key]

        keys ->
          keys
      end

    sim = %{sim | settings: Settings.put(sim.settings, key, value)}

    setting_change(sim, keys, "set #{Command.setting(path)}", opts)
  end

  defp run_op(sim, {:unset, path, from}, opts) do
    key = Enum.join(path, ".")
    check_setting!(sim, "unset", path, key, from)

    keys =
      case sim.settings |> Settings.slice(key) |> Map.keys() do
        [] ->
          [key]

        keys ->
          keys
      end

    sim = %{sim | settings: Settings.delete(sim.settings, key)}

    setting_change(sim, keys, "unset #{Command.setting(path)}", opts)
  end

  defp run_op(sim, {:script, source, params, _reverse}, _opts) do
    copy(sim, {:script, source, params}, "a script")
  end

  defp setting_change(sim, keys, reason, opts) do
    dynamic? = Keyword.fetch!(opts, :dynamic?)

    if Enum.all?(keys, dynamic?) do
      sim
    else
      copy(sim, nil, reason <> " (a static setting)")
    end
  end

  # Notes that the documents must be copied — only for an existing index: an
  # index created in this run is created as it ends up, with nothing to copy.
  defp copy(%{mode: :existing} = sim, data_op, reason) do
    data_ops = if data_op, do: sim.data_ops ++ [data_op], else: sim.data_ops

    %{sim | data_ops: data_ops, reasons: sim.reasons ++ [reason]}
  end

  defp copy(sim, _data_op, _reason), do: sim

  defp fetch_field!(sim, op, path) do
    case Properties.fetch(sim.mappings, path) do
      {:ok, field} ->
        field

      :error ->
        fail(sim, "#{op} #{Command.field(path)}: the field doesn't exist")
    end
  end

  defp check_definition!(_sim, _op, _path, _current, :error), do: :ok

  defp check_definition!(sim, op, path, current, {:ok, expected}) do
    unless Properties.same?(current, expected) do
      fail(
        sim,
        "#{op} #{Command.field(path)}: the field is #{inspect(current)}, " <>
          "the migration expects #{inspect(expected)}"
      )
    end

    :ok
  end

  defp check_setting!(_sim, _op, _path, _key, :error), do: :ok

  defp check_setting!(sim, op, path, key, {:ok, expected}) do
    current = Settings.slice(sim.settings, key)

    unless Settings.same?(current, Settings.at(key, expected)) do
      fail(
        sim,
        "#{op} #{Command.setting(path)}: it is #{describe_setting(current, key)}, " <>
          "the migration expects #{inspect(expected)} (from:)"
      )
    end

    :ok
  end

  defp describe_setting(current, key) when map_size(current) == 0 and is_binary(key),
    do: "not set"

  defp describe_setting(current, key) do
    case Map.fetch(current, key) do
      {:ok, value} ->
        inspect(value)

      :error ->
        inspect(current)
    end
  end

  ## Steps

  defp finish(%{mode: :absent} = sim, _direction, _opts), do: group(sim, nil)

  defp finish(%{mode: :new} = sim, _direction, _opts) do
    aliases = sim.extra |> Map.get("aliases", %{}) |> Map.put(sim.index, %{})

    body =
      sim.extra
      |> Map.put("aliases", aliases)
      |> Map.put("mappings", sim.mappings)
      |> put_settings(sim.settings)

    group(%{sim | steps: [{:create_index, sim.physical, body} | sim.steps]}, nil)
  end

  defp finish(%{mode: :existing, changed: false} = sim, _direction, _opts), do: group(sim, nil)

  defp finish(%{mode: :existing, reasons: []} = sim, _direction, _opts) do
    settings =
      case Settings.diff(sim.base_settings, sim.settings) do
        empty when map_size(empty) == 0 ->
          []

        diff ->
          [{:put_settings, sim.physical, diff}]
      end

    mapping =
      sim.mappings
      |> Properties.subset(sim.added)
      |> Map.put("_meta", Map.fetch!(sim.mappings, "_meta"))

    steps = [{:put_mapping, sim.physical, mapping} | Enum.reverse(settings)]

    group(%{sim | steps: steps ++ sim.steps}, nil)
  end

  defp finish(%{mode: :existing} = sim, direction, opts) do
    previous = if direction == :down, do: previous_copy(sim)

    cond do
      previous ->
        switch(sim, previous, opts)

      Keyword.fetch!(opts, :reindex) ->
        reindex(sim, opts)

      true ->
        fail(
          sim,
          "the documents must be copied into a new index (#{Enum.join(Enum.uniq(sim.reasons), ", ")}); " <>
            "run again with --reindex"
        )
    end
  end

  # A rollback finding the copy the index was made from: the alias moves back
  # onto it — the documents written since then aren't in it.
  defp previous_copy(sim) do
    Enum.find_value(sim.others, fn {physical, version} ->
      if version == sim.version, do: physical
    end)
  end

  defp switch(sim, previous, opts) do
    current = sim.physical
    delete_previous = Keyword.fetch!(opts, :delete_previous)

    steps =
      [
        {:remove_write_block, previous},
        {:swap_alias, sim.index, current, previous},
        if(delete_previous, do: {:delete_index, current}, else: {:add_write_block, current})
      ]

    group(%{sim | steps: Enum.reverse(steps) ++ sim.steps}, nil)
  end

  defp reindex(sim, opts) do
    source = sim.physical
    dest = pick_name(sim, sim.version)
    block = Keyword.fetch!(opts, :write_block)
    body = put_settings(%{"mappings" => sim.mappings}, sim.settings)

    steps =
      Enum.reject(
        [
          block && {:add_write_block, source},
          {:create_index, dest, body},
          {:reindex, source, dest, Script.build(sim.data_ops)},
          {:swap_alias, sim.index, source, dest},
          Keyword.fetch!(opts, :delete_previous) && {:delete_index, source}
        ],
        &(&1 in [nil, false])
      )

    group(%{sim | steps: Enum.reverse(steps) ++ sim.steps}, %{
      source: source,
      dest: dest,
      blocked: block
    })
  end

  defp group(sim, copy) do
    {%{index: sim.index, steps: Enum.reverse(sim.steps), copy: copy}, sim.taken}
  end

  defp put_settings(body, settings) when map_size(settings) == 0, do: body
  defp put_settings(body, settings), do: Map.put(body, "settings", Settings.body(settings))

  defp put_meta(mappings, version) do
    meta = mappings |> Map.get("_meta", %{}) |> Map.put("dowser_version", version)

    Map.put(mappings, "_meta", meta)
  end

  defp pick_name(sim, version) do
    base = sim.index <> sim.separator <> to_string(version)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 ->
        base

      n ->
        base <> sim.separator <> to_string(n)
    end)
    |> Enum.find(&(not MapSet.member?(sim.taken, &1)))
  end

  ## Errors

  defp fail(%{migration: migration, index: index}, message) do
    fail("migration #{migration.version} (#{migration.name}), #{index}: #{message}")
  end

  defp fail(message), do: raise(Error, message)

  ## Describing a plan

  @doc "A step as the request it sends, for `--dry-run`."
  @spec describe(step()) :: String.t()
  def describe({:create_index, index, body}), do: "PUT /#{index} #{JSON.encode!(body)}"
  def describe({:delete_index, index}), do: "DELETE /#{index}"
  def describe({:put_mapping, index, body}), do: "PUT /#{index}/_mapping #{JSON.encode!(body)}"
  def describe({:put_settings, index, body}), do: "PUT /#{index}/_settings #{JSON.encode!(body)}"
  def describe({:add_write_block, index}), do: "PUT /#{index}/_block/write"

  def describe({:remove_write_block, index}) do
    "PUT /#{index}/_settings #{JSON.encode!(%{"index.blocks.write" => nil})}"
  end

  def describe({:reindex, source, dest, script}) do
    body = %{"source" => %{"index" => source}, "dest" => %{"index" => dest}}
    body = if script, do: Map.put(body, "script", script), else: body

    "POST /_reindex?wait_for_completion=false #{JSON.encode!(body)}"
  end

  def describe({:swap_alias, name, from, to}) do
    actions = [
      %{"remove" => %{"index" => from, "alias" => name}},
      %{"add" => %{"index" => to, "alias" => name}}
    ]

    "POST /_aliases #{JSON.encode!(%{"actions" => actions})}"
  end
end
