defmodule Dowser.Migration.Runner do
  @moduledoc false

  # Runs a plan (see `Dowser.Migration.Planner`) through an adapter: each
  # group's steps in order, then the records that group completes.
  #
  # A group copying an index is guarded. Before blocking writes, the lock
  # records what the copy is about to change; if a step fails before the alias
  # moves, the copy is undone — the new index deleted, the old one unblocked —
  # and the lock cleared. If that undoing fails too, or the node dies, the lock
  # keeps the state for `Dowser.Migrator.recover/2`.

  require Logger

  alias Dowser.Migration.Error
  alias Dowser.Migration.Planner

  @doc """
  Runs `plan`; `{:error, exception, keep_lock?}` when a step failed —
  `keep_lock?` when a copy couldn't be undone.
  """
  @spec execute(Planner.plan(), Dowser.Repo.t(), module(), keyword()) ::
          :ok | {:error, Exception.t(), boolean()}
  def execute(plan, repo, adapter, opts) do
    records = Enum.group_by(plan.records, &elem(&1, 0), &elem(&1, 1))
    ctx = %{repo: repo, adapter: adapter, opts: opts}

    run_records(ctx, Map.get(records, -1, []))

    plan.groups
    |> Enum.with_index()
    |> Enum.each(fn {group, position} ->
      run_group(ctx, group)
      run_records(ctx, Map.get(records, position, []))
    end)
  catch
    {__MODULE__, exception, keep_lock?} ->
      {:error, exception, keep_lock?}
  else
    _result ->
      :ok
  end

  defp run_records(ctx, records) do
    Enum.each(records, fn
      {:record, record} ->
        ctx |> call(:record, [record]) |> check!("recording migration #{record["version"]}")
        log(ctx, :info, "migrated #{record["version"]} (#{record["name"]})")

      {:unrecord, version} ->
        ctx |> call(:unrecord, [version]) |> check!("removing the record of migration #{version}")
        log(ctx, :info, "rolled back #{version}")
    end)
  end

  defp run_group(ctx, %{copy: nil} = group) do
    Enum.each(group.steps, &run_step(ctx, group.index, &1))
  end

  defp run_group(ctx, %{copy: copy} = group) do
    state = %{
      "phase" => "copy",
      "index" => group.index,
      "source" => copy.source,
      "dest" => copy.dest,
      "blocked" => copy.blocked
    }

    ctx |> update_lock(state) |> check!("recording the copy in the lock")

    swapped =
      Enum.reduce(group.steps, false, fn step, swapped ->
        try do
          run_step(ctx, group.index, step)
        catch
          {__MODULE__, exception, _keep_lock?} when not swapped ->
            undo(ctx, group, exception)
        end

        swapped or match?({:swap_alias, _name, _from, _to}, step)
      end)

    true = swapped
    ctx |> update_lock(nil) |> check!("clearing the lock")
  end

  # The copy failed before the alias moved: the old index is still the one in
  # use — unblock it, and delete the incomplete new one.
  @spec undo(map(), Planner.group(), Exception.t()) :: no_return()
  defp undo(ctx, group, exception) do
    %{source: source, dest: dest, blocked: blocked} = group.copy

    log(ctx, :error, "#{group.index}: #{Exception.message(exception)}; undoing the copy")

    result =
      with :ok <- if(blocked, do: call(ctx, :remove_write_block, [source]), else: :ok),
           :ok <- delete_if_exists(ctx, dest) do
        update_lock(ctx, nil)
      end

    case result do
      :ok ->
        throw({__MODULE__, exception, false})

      {:error, reason} ->
        message =
          "#{Exception.message(exception)}; undoing the copy failed too (#{format(reason)}): " <>
            "#{source} may still block writes and #{dest} exist — run mix dowser.recover"

        throw({__MODULE__, %Error{message: message}, true})
    end
  end

  defp delete_if_exists(ctx, index) do
    case call(ctx, :get_indices, [[index]]) do
      {:ok, %{^index => _index}} ->
        call(ctx, :delete_index, [index])

      {:ok, _none} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_step(ctx, index, step) do
    log(ctx, :info, "#{index}: #{summary(step)}")
    log(ctx, :debug, Planner.describe(step))

    case step do
      {:reindex, source, dest, script} ->
        ctx |> call(:reindex, [source, dest, script]) |> check!(step) |> await(ctx, step)

      {name, arg} ->
        ctx |> call(name, [arg]) |> check!(step)

      {name, arg1, arg2} ->
        ctx |> call(name, [arg1, arg2]) |> check!(step)

      {name, arg1, arg2, arg3} ->
        ctx |> call(name, [arg1, arg2, arg3]) |> check!(step)
    end
  end

  defp await(task, ctx, step) do
    case call(ctx, :get_task, [task]) do
      {:ok, %{"completed" => true} = status} ->
        reindexed(status, step)

      {:ok, status} ->
        progress(ctx, status)
        Process.sleep(Keyword.get(ctx.opts, :poll_interval, 1_000))
        await(task, ctx, step)

      {:error, reason} ->
        error!(reason, "following #{summary(step)} (task #{task})")
    end
  end

  defp reindexed(%{"error" => error}, step) do
    error!(error, step)
  end

  defp reindexed(%{"response" => %{"failures" => [_ | _] = failures}}, step) do
    error!({:failures, Enum.take(failures, 5)}, step)
  end

  defp reindexed(_status, _step), do: :ok

  defp progress(ctx, %{"task" => %{"status" => %{"total" => total} = status}}) when total > 0 do
    done = Map.get(status, "created", 0) + Map.get(status, "updated", 0)

    log(ctx, :info, "  #{done}/#{total} documents copied")
  end

  defp progress(_ctx, _status), do: :ok

  defp update_lock(ctx, state) do
    call(ctx, :update_lock, [%{"owner" => owner(), "state" => state}])
  end

  @doc false
  def owner, do: "#{node()} #{inspect(self())}"

  defp call(ctx, name, args), do: apply(ctx.adapter, name, [ctx.repo | args])

  defp check!(:ok, _what), do: :ok
  defp check!({:ok, result}, _what), do: result

  defp check!({:error, reason}, what), do: error!(reason, what)

  @spec error!(term(), String.t() | Planner.step()) :: no_return()
  defp error!(reason, what) do
    what = if is_binary(what), do: what, else: summary(what)

    throw({__MODULE__, %Error{message: "#{what} failed: #{format(reason)}"}, false})
  end

  @doc false
  @spec format(term()) :: String.t()
  def format(%{__exception__: true} = exception), do: Exception.message(exception)
  def format(reason), do: inspect(reason)

  @doc "A step in a few words."
  @spec summary(Planner.step()) :: String.t()
  def summary({:create_index, index, _body}), do: "create #{index}"
  def summary({:delete_index, index}), do: "delete #{index}"
  def summary({:put_mapping, index, _body}), do: "update the mapping of #{index}"
  def summary({:put_settings, index, _body}), do: "update the settings of #{index}"
  def summary({:add_write_block, index}), do: "block writes to #{index}"
  def summary({:remove_write_block, index}), do: "unblock writes to #{index}"
  def summary({:reindex, source, dest, _script}), do: "copy #{source} into #{dest}"
  def summary({:swap_alias, name, from, to}), do: "move alias #{name} from #{from} to #{to}"

  defp log(ctx, level, message) do
    case Keyword.get(ctx.opts, :log, :info) do
      false ->
        :ok

      _level ->
        Logger.log(level, message)
    end
  end
end
