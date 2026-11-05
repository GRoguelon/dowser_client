defmodule Dowser.Migration.Command do
  @moduledoc false

  # The commands a migration records (see `Dowser.Migration`), and how
  # `change/0`'s are inverted for a rollback.
  #
  #   {:create_index, name, body, opts}       (opts: :separator)
  #   {:drop_index, name, body | nil}
  #   {:alter_index, name, from_version | nil, [op]}
  #
  # with the operations
  #
  #   {:add, path, definition, {:ok, default} | :error}
  #   {:modify, path, definition, {:ok, from} | :error}
  #   {:rename, path, to}
  #   {:remove, path, definition | nil}
  #   {:set, setting_path, value, {:ok, from} | :error}
  #   {:unset, setting_path, {:ok, from} | :error}
  #   {:script, source, params, {:ok, reverse} | :error}

  alias Dowser.Migration.IrreversibleError

  @type t :: tuple()

  @doc "The index a command changes."
  @spec index(t()) :: String.t()
  def index(command), do: elem(command, 1)

  @doc """
  Inverts `change/0`'s commands: each inverted, in reverse order. Raises an
  `IrreversibleError` naming the first one that can't be.
  """
  @spec invert([t()]) :: [t()]
  def invert(commands) do
    commands |> Enum.reverse() |> Enum.map(&invert_command/1)
  end

  defp invert_command({:create_index, name, body, _opts}), do: {:drop_index, name, body}

  defp invert_command({:drop_index, name, nil}) do
    irreversible("drop_index #{inspect(name)} without the index's body")
  end

  # Recreated with the separator of the index it drops; see the planner.
  defp invert_command({:drop_index, name, body}), do: {:create_index, name, body, []}

  defp invert_command({:alter_index, name, _from, ops}) do
    {:alter_index, name, nil, ops |> Enum.reverse() |> Enum.map(&invert_op(name, &1))}
  end

  defp invert_op(_name, {:add, path, definition, _default}), do: {:remove, path, definition}

  defp invert_op(name, {:modify, path, _definition, :error}) do
    irreversible("modify #{field(path)} in #{inspect(name)} without from:")
  end

  defp invert_op(_name, {:modify, path, definition, {:ok, from}}) do
    {:modify, path, from, {:ok, definition}}
  end

  defp invert_op(_name, {:rename, path, to}) do
    {:rename, List.replace_at(path, -1, to), List.last(path)}
  end

  defp invert_op(name, {:remove, path, nil}) do
    irreversible("remove #{field(path)} in #{inspect(name)} without its definition")
  end

  defp invert_op(_name, {:remove, path, definition}), do: {:add, path, definition, :error}

  defp invert_op(name, {:set, path, _value, :error}) do
    irreversible("set #{setting(path)} in #{inspect(name)} without from:")
  end

  defp invert_op(_name, {:set, path, value, {:ok, nil}}), do: {:unset, path, {:ok, value}}
  defp invert_op(_name, {:set, path, value, {:ok, from}}), do: {:set, path, from, {:ok, value}}

  defp invert_op(name, {:unset, path, :error}) do
    irreversible("unset #{setting(path)} in #{inspect(name)} without from:")
  end

  defp invert_op(_name, {:unset, path, {:ok, nil}}), do: {:unset, path, {:ok, nil}}
  defp invert_op(_name, {:unset, path, {:ok, from}}), do: {:set, path, from, {:ok, nil}}

  defp invert_op(name, {:script, _source, _params, :error}) do
    irreversible("a script in #{inspect(name)} without reverse:")
  end

  defp invert_op(_name, {:script, source, params, {:ok, reverse}}) do
    {:script, reverse, params, {:ok, source}}
  end

  @doc "A field path as written in messages: `comments.body`."
  @spec field([String.t()]) :: String.t()
  def field(path), do: Enum.join(path, ".")

  @doc "A setting path as written in messages: `index.number_of_replicas`."
  @spec setting([String.t()]) :: String.t()
  def setting(path), do: Enum.join(["index" | path], ".")

  @spec irreversible(String.t()) :: no_return()
  defp irreversible(what) do
    raise IrreversibleError,
          "cannot roll back #{what}; define up/0 and down/0, or give what reverts it"
  end
end
