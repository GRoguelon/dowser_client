defmodule Dowser.Test.FakeCluster do
  @moduledoc false

  # An in-memory cluster implementing `Dowser.Migration.Adapter`, for the
  # migrator's tests: the "repo" is the pid of the agent holding it.
  #
  # Copies run the field operations of the reindex script with an Elixir
  # mirror of the painless routine (`Dowser.Migration.Script`); a `script/2`
  # source runs the function registered for it with `scripts/2`. A strict
  # mapping rejects a copied document holding an unmapped field, as the
  # engine would. `fail/3` makes a callback fail.

  use Dowser.Migration.Adapter

  alias Dowser.Migration.Script
  alias Dowser.Migration.Settings

  @routine_call ~r/\AdowserApply\(ctx\._source, params\.(\w+)\);\z/

  def start do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{indices: %{}, records: %{}, lock: nil, tasks: %{}, fail: %{}, scripts: %{}, calls: []}
      end)

    pid
  end

  ## Test helpers

  def state(pid), do: Agent.get(pid, & &1)
  def index(pid, name), do: Agent.get(pid, &get_in(&1, [:indices, name]))
  def calls(pid), do: pid |> Agent.get(& &1.calls) |> Enum.reverse()

  def fail(pid, callback, reason) do
    Agent.update(pid, &put_in(&1, [:fail, callback], reason))
  end

  def unfail(pid, callback) do
    Agent.update(pid, fn state -> %{state | fail: Map.delete(state.fail, callback)} end)
  end

  def scripts(pid, scripts), do: Agent.update(pid, &Map.put(&1, :scripts, scripts))

  # Indexes documents through the alias, as the application would: refused
  # while writes are blocked.
  def put_docs(pid, index, docs) do
    Agent.get_and_update(pid, &put_docs_in(&1, physical(&1, index), docs))
  end

  defp put_docs_in(state, nil, _docs), do: {{:error, :index_not_found}, state}

  defp put_docs_in(state, physical, docs) do
    if get_in(state, [:indices, physical, "blocked"]) do
      {{:error, :blocked}, state}
    else
      {:ok, update_in(state, [:indices, physical, "docs"], &Map.merge(&1, docs))}
    end
  end

  def docs(pid, index) do
    Agent.get(pid, fn state -> get_in(state, [:indices, physical(state, index), "docs"]) end)
  end

  defp physical(state, name) do
    if Map.has_key?(state.indices, name) do
      name
    else
      Enum.find_value(state.indices, fn {physical, index} ->
        name in index["aliases"] && physical
      end)
    end
  end

  ## Adapter

  @impl true
  def ensure_tracking(pid), do: call(pid, :ensure_tracking, fn state -> {:ok, state} end)

  @impl true
  def applied(pid),
    do: call(pid, :applied, fn state -> {{:ok, Map.values(state.records)}, state} end)

  @impl true
  def record(pid, record) do
    call(pid, :record, fn state -> {:ok, put_in(state, [:records, record["version"]], record)} end)
  end

  @impl true
  def unrecord(pid, version) do
    call(pid, :unrecord, fn state -> {:ok, update_in(state.records, &Map.delete(&1, version))} end)
  end

  @impl true
  def lock(pid, lock) do
    call(pid, :lock, fn
      %{lock: nil} = state ->
        {:ok, %{state | lock: lock}}

      state ->
        {{:error, {:locked, state.lock}}, state}
    end)
  end

  @impl true
  def get_lock(pid), do: call(pid, :get_lock, fn state -> {{:ok, state.lock}, state} end)

  @impl true
  def update_lock(pid, lock) do
    call(pid, :update_lock, fn state ->
      {:ok, %{state | lock: Map.merge(state.lock || %{}, lock)}}
    end)
  end

  @impl true
  def unlock(pid), do: call(pid, :unlock, fn state -> {:ok, %{state | lock: nil}} end)

  @impl true
  def get_indices(pid, names) do
    call(pid, {:get_indices, names}, fn state ->
      found =
        for {physical, index} <- state.indices,
            Enum.any?(names, &matches?(&1, physical, index)),
            into: %{} do
          {physical, Map.take(index, ["mappings", "settings", "aliases"])}
        end

      {{:ok, found}, state}
    end)
  end

  defp matches?(name, physical, index) do
    if String.contains?(name, "*") do
      regex = name |> Regex.escape() |> String.replace("\\*", ".*")
      Regex.match?(~r/\A#{regex}\z/, physical)
    else
      name == physical or name in index["aliases"]
    end
  end

  @impl true
  def create_index(pid, name, body) do
    call(pid, {:create_index, name}, fn state ->
      requested = body |> Map.get("settings", %{}) |> Settings.flatten()

      cond do
        physical(state, name) ->
          {{:error, :resource_already_exists}, state}

        Settings.copyable(requested) != requested ->
          {{:error,
            {:private_settings,
             requested |> Map.drop(Map.keys(Settings.copyable(requested))) |> Map.keys()}}, state}

        true ->
          settings =
            requested
            |> Map.merge(%{
              "uuid" => "u-#{name}",
              "creation_date" => "1",
              "provided_name" => name,
              "version.created" => "1"
            })
            |> Map.put_new("number_of_shards", "1")
            |> Map.put_new("number_of_replicas", "1")

          index = %{
            "mappings" => Map.get(body, "mappings", %{}),
            "settings" => settings,
            "aliases" => body |> Map.get("aliases", %{}) |> Map.keys(),
            "docs" => %{},
            "blocked" => false
          }

          {:ok, put_in(state, [:indices, name], index)}
      end
    end)
  end

  @impl true
  def delete_index(pid, name) do
    call(pid, {:delete_index, name}, fn state ->
      if Map.has_key?(state.indices, name) do
        {:ok, update_in(state.indices, &Map.delete(&1, name))}
      else
        {{:error, :index_not_found}, state}
      end
    end)
  end

  @impl true
  def put_mapping(pid, name, body) do
    call(pid, {:put_mapping, name}, fn state ->
      state =
        update_in(state, [:indices, name, "mappings"], fn mappings ->
          mappings |> deep_merge(Map.delete(body, "_meta")) |> Map.put("_meta", body["_meta"])
        end)

      {:ok, state}
    end)
  end

  @impl true
  def put_settings(pid, name, settings) do
    call(pid, {:put_settings, name}, fn state ->
      {:ok, update_in(state, [:indices, name, "settings"], &apply_settings(&1, settings))}
    end)
  end

  defp apply_settings(current, settings) do
    Enum.reduce(Settings.flatten(settings), current, fn
      {key, nil}, acc ->
        Map.delete(acc, key)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  @impl true
  def add_write_block(pid, name) do
    call(pid, {:add_write_block, name}, fn state ->
      state =
        state
        |> put_in([:indices, name, "blocked"], true)
        |> put_in([:indices, name, "settings", "blocks.write"], "true")

      {:ok, state}
    end)
  end

  @impl true
  def remove_write_block(pid, name) do
    call(pid, {:remove_write_block, name}, fn state ->
      state =
        state
        |> put_in([:indices, name, "blocked"], false)
        |> update_in([:indices, name, "settings"], &Map.delete(&1, "blocks.write"))

      {:ok, state}
    end)
  end

  @impl true
  def swap_alias(pid, name, from, to) do
    call(pid, {:swap_alias, name, from, to}, fn state ->
      state =
        state
        |> update_in([:indices, from, "aliases"], &List.delete(&1, name))
        |> update_in([:indices, to, "aliases"], &[name | &1])

      {:ok, state}
    end)
  end

  @impl true
  def reindex(pid, source, dest, script) do
    call(pid, {:reindex, source, dest}, fn state ->
      mapping = get_in(state, [:indices, dest, "mappings"])

      {copied, failed} =
        state
        |> get_in([:indices, source, "docs"])
        |> Enum.map(fn {id, doc} -> {id, copy_doc(state, script, mapping, doc)} end)
        |> Enum.split_with(&match?({_id, {:ok, _doc}}, &1))

      docs = Map.new(copied, fn {id, {:ok, doc}} -> {id, doc} end)

      failures =
        Enum.map(failed, fn {id, {:error, reason}} -> %{"id" => id, "cause" => reason} end)

      task = "task-#{map_size(state.tasks) + 1}"

      status = %{
        "completed" => true,
        "response" => %{
          "total" => map_size(docs),
          "created" => map_size(docs),
          "failures" => failures
        }
      }

      state =
        state
        |> update_in([:indices, dest, "docs"], &Map.merge(&1, docs))
        |> put_in([:tasks, task], status)

      {{:ok, task}, state}
    end)
  end

  defp copy_doc(state, script, mapping, doc) do
    with {:ok, doc} <- run_script(state, script, doc) do
      case unmapped(mapping, doc) do
        [] ->
          {:ok, doc}

        fields ->
          {:error, {:strict_dynamic_mapping, fields}}
      end
    end
  end

  @impl true
  def get_task(pid, task) do
    call(pid, {:get_task, task}, fn state -> {{:ok, state.tasks[task]}, state} end)
  end

  ## Plumbing

  defp call(pid, call, fun) do
    Agent.get_and_update(pid, fn state ->
      name = if is_tuple(call), do: elem(call, 0), else: call
      state = %{state | calls: [call | state.calls]}

      case state.fail do
        %{^name => reason} ->
          {{:error, reason}, state}

        _none ->
          fun.(state)
      end
    end)
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r ->
        deep_merge(l, r)

      _key, _l, r ->
        r
    end)
  end

  ## The script

  defp run_script(_state, nil, doc), do: {:ok, doc}

  defp run_script(state, %{"source" => source, "params" => params}, doc) do
    routine = String.trim_trailing(Script.routine())
    true = String.starts_with?(source, routine)

    source
    |> String.replace_prefix(routine, "")
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, doc}, fn statement, {:ok, doc} ->
      case run_statement(state, statement, params, doc) do
        {:ok, doc} ->
          {:cont, {:ok, doc}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp run_statement(state, statement, params, doc) do
    case Regex.run(@routine_call, statement) do
      [_match, key] ->
        apply_ops(doc, Map.fetch!(params, key))

      nil ->
        {:ok, Map.fetch!(state.scripts, statement).(doc, params)}
    end
  end

  @doc false
  # The Elixir mirror of the painless routine.
  def apply_ops(doc, ops) do
    {:ok, Enum.reduce(ops, doc, &walk(&2, &1["path"], 0, &1))}
  catch
    {:rename_conflict, from, to} ->
      {:error, "cannot rename [#{from}] to [#{to}]: [#{to}] already exists"}
  end

  defp walk(nodes, path, i, op) when is_list(nodes), do: Enum.map(nodes, &walk(&1, path, i, op))

  defp walk(%{} = node, path, i, op) do
    n = length(path)

    # Each key the rest of the path can be stored under — `a`, `a.b`, … —
    # walked into, then the leaf, as the routine does.
    {node, prefix} =
      Enum.reduce(i..(n - 1)//1, {node, ""}, fn j, {node, prefix} ->
        segment = Enum.at(path, j)
        prefix = if prefix == "", do: segment, else: prefix <> "." <> segment

        {walk_key(node, prefix, path, j + 1, op), prefix}
      end)

    leaf(node, if(i == n, do: "", else: prefix <> "."), i == n, op)
  end

  defp walk(other, _path, _i, _op), do: other

  defp walk_key(node, key, path, i, op) do
    case node do
      %{^key => child} when not is_nil(child) ->
        Map.put(node, key, walk(child, path, i, op))

      _missing ->
        node
    end
  end

  defp leaf(node, prefix, _direct, %{"op" => "remove", "field" => field}) do
    Map.delete(node, prefix <> field)
  end

  defp leaf(node, prefix, _direct, %{"op" => "rename", "from" => from, "to" => to}) do
    from = prefix <> from
    to = prefix <> to

    cond do
      not Map.has_key?(node, from) ->
        node

      Map.has_key?(node, to) ->
        throw({:rename_conflict, from, to})

      true ->
        {value, node} = Map.pop(node, from)
        Map.put(node, to, value)
    end
  end

  defp leaf(node, _prefix, true, %{"op" => "add", "field" => field, "value" => value}) do
    Map.put_new(node, field, value)
  end

  defp leaf(node, _prefix, false, %{"op" => "add"}), do: node

  ## Strict mappings

  defp unmapped(mapping, doc) do
    if Map.get(mapping, "dynamic") in ["strict", :strict] do
      unmapped_fields(Map.get(mapping, "properties", %{}), doc, [])
    else
      []
    end
  end

  defp unmapped_fields(properties, list, path) when is_list(list) do
    Enum.flat_map(list, &unmapped_fields(properties, &1, path))
  end

  defp unmapped_fields(properties, %{} = doc, path) do
    Enum.flat_map(doc, fn {key, value} ->
      case properties do
        %{^key => %{"properties" => nested}} ->
          unmapped_fields(nested, value, path ++ [key])

        %{^key => _field} ->
          []

        _unmapped ->
          [Enum.join(path ++ [key], ".")]
      end
    end)
  end

  defp unmapped_fields(_properties, _value, _path), do: []
end
