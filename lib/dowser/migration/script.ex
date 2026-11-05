defmodule Dowser.Migration.Script do
  @moduledoc false

  # The painless script a copy runs on each document.
  #
  # Field operations never become painless source: they are data —
  # `params.dowser_ops_<n>` — read by one routine shipped here, so a field name
  # or a default value can't break or inject into the script, and the source
  # stays the same from one migration to the next (compiled once, cached by the
  # engine). Only `script/2`'s own source is inserted, between the routine's
  # calls.
  #
  # The routine walks `_source` as stored, whatever the mapping says:
  #
  #   * a missing or `null` value on the way: skipped;
  #   * a map: walked into;
  #   * a list: each element walked, lists of lists included;
  #   * anything else where an object was expected: skipped;
  #   * a dotted key (`"address.zip"`), which the engine takes for
  #     `address → zip`: walked as such.
  #
  # The list of nodes to visit grows while it is walked, rather than recursing
  # or removing from it, so its depth is unbounded and only List.get/add are
  # used.

  @routine """
  void dowserApply(Map source, List ops) {
    for (int o = 0; o < ops.size(); o++) {
      Map op = ops.get(o);
      List path = op.get('path');
      int n = path.size();
      List nodes = new ArrayList();
      List depths = new ArrayList();
      nodes.add(source);
      depths.add(0);
      for (int k = 0; k < nodes.size(); k++) {
        def node = nodes.get(k);
        int i = depths.get(k);
        if (node instanceof List) {
          for (def item : node) {
            nodes.add(item);
            depths.add(i);
          }
        } else if (node instanceof Map) {
          String prefix = '';
          for (int j = i; j < n; j++) {
            String segment = path.get(j);
            prefix = prefix.isEmpty() ? segment : prefix + '.' + segment;
            def child = node.get(prefix);
            if (child != null) {
              nodes.add(child);
              depths.add(j + 1);
            }
          }
          dowserLeaf(node, i == n ? '' : prefix + '.', i == n, op);
        }
      }
    }
  }

  void dowserLeaf(Map node, String prefix, boolean direct, Map op) {
    String kind = op.get('op');
    if (kind == 'remove') {
      node.remove(prefix + op.get('field'));
    } else if (kind == 'rename') {
      String from = prefix + op.get('from');
      if (node.containsKey(from)) {
        String to = prefix + op.get('to');
        if (node.containsKey(to)) {
          throw new IllegalArgumentException('cannot rename [' + from + '] to [' + to + ']: [' + to + '] already exists');
        }
        node.put(to, node.remove(from));
      }
    } else if (kind == 'add') {
      if (direct && !node.containsKey(op.get('field'))) {
        node.put(op.get('field'), op.get('value'));
      }
    }
  }
  """

  @doc "The routine's painless source."
  @spec routine() :: String.t()
  def routine, do: @routine

  @doc """
  The reindex `script` for the operations changing documents, in order —
  `{:rename, path, to}`, `{:remove, path}`, `{:add, path, default}`,
  `{:script, source, params}` — or `nil` when there are none.
  """
  @spec build([tuple()]) :: map() | nil
  def build([]), do: nil

  def build(ops) do
    {statements, params} =
      ops
      |> Enum.chunk_by(&match?({:script, _source, _params}, &1))
      |> Enum.with_index()
      |> Enum.flat_map_reduce(%{}, &segment/2)

    %{
      "lang" => "painless",
      "source" => Enum.join([String.trim_trailing(@routine) | statements], "\n"),
      "params" => params
    }
  end

  defp segment({[{:script, _source, _params} | _rest] = scripts, _index}, params) do
    Enum.map_reduce(scripts, params, fn {:script, source, own}, params ->
      {source, merge_params(params, own)}
    end)
  end

  defp segment({ops, index}, params) do
    key = "dowser_ops_#{index}"

    {["dowserApply(ctx._source, params.#{key});"], Map.put(params, key, Enum.map(ops, &op/1))}
  end

  defp op({:rename, path, to}) do
    {parent, [from]} = Enum.split(path, -1)

    %{"op" => "rename", "path" => parent, "from" => from, "to" => to}
  end

  defp op({:remove, path}) do
    {parent, [field]} = Enum.split(path, -1)

    %{"op" => "remove", "path" => parent, "field" => field}
  end

  defp op({:add, path, value}) do
    {parent, [field]} = Enum.split(path, -1)

    %{"op" => "add", "path" => parent, "field" => field, "value" => value}
  end

  defp merge_params(params, own) do
    Map.merge(params, own, fn key, left, right ->
      if left == right do
        left
      else
        raise Dowser.Migration.Error,
              "two scripts of one copy give the parameter #{inspect(key)} different values"
      end
    end)
  end
end
