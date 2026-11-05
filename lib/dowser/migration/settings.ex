defmodule Dowser.Migration.Settings do
  @moduledoc false

  # Index settings as the migrator handles them: flat, relative to `index` —
  # `%{"number_of_replicas" => "1", "analysis.analyzer.folded.tokenizer" =>
  # "standard"}` — the shape `flat_settings=true` returns, without its
  # `index.` prefix.

  # Settings the engine changes on a live index. Anything else is treated as
  # static: changing it copies the documents into a new index.
  @dynamic ~w[
    number_of_replicas auto_expand_replicas refresh_interval hidden priority
    max_result_window max_inner_result_window max_rescore_window
    max_docvalue_fields_search max_script_fields max_ngram_diff max_shingle_diff
    max_refresh_listeners max_terms_count max_regex_length max_slices_per_scroll
    default_pipeline final_pipeline gc_deletes query.default_field search.idle.after
    analyze.max_token_count highlight.max_analyzed_offset
    unassigned.node_left.delayed_timeout
    mapping.total_fields.limit mapping.depth.limit mapping.nested_fields.limit
    mapping.nested_objects.limit mapping.field_name_length.limit
    translog.durability translog.sync_interval translog.flush_threshold_size
  ]

  @dynamic_groups ~w[
    blocks. routing. merge. search.slowlog. indexing.slowlog. lifecycle. plugins.
  ]

  # Settings the engine sets on an index itself: never copied to the index the
  # documents are copied into.
  @internal ~w[uuid creation_date creation_date_string provided_name verified_before_close]
  @internal_groups ~w[version. blocks. resize. shrink. history. routing.allocation.initial_recovery.]

  @type t :: %{String.t() => term()}

  @doc "Whether the engine changes `key` on a live index."
  @spec dynamic?(String.t()) :: boolean()
  def dynamic?(key) do
    key in @dynamic or Enum.any?(@dynamic_groups, &String.starts_with?(key, &1))
  end

  @doc """
  Flattens a `settings` body — nested (`%{"index" => %{...}}`), flat
  (`"index.number_of_replicas"`) or relative (`"number_of_replicas"`).
  """
  @spec flatten(map() | nil) :: t()
  def flatten(nil), do: %{}

  def flatten(%{} = settings) do
    settings
    |> flatten("")
    |> Map.new(fn {key, value} -> {strip(key), value} end)
  end

  defp flatten(%{} = map, prefix) do
    Enum.flat_map(map, fn {key, value} ->
      key = prefix <> to_string(key)

      case value do
        %{} = nested when not is_struct(nested) ->
          flatten(nested, key <> ".")

        value ->
          [{key, value}]
      end
    end)
  end

  defp strip("index." <> key), do: key
  defp strip(key), do: key

  @doc "The settings a copy of an index starts from: `settings` without the engine's own."
  @spec copyable(t()) :: t()
  def copyable(settings) do
    Map.reject(settings, fn {key, _value} ->
      key in @internal or Enum.any?(@internal_groups, &String.starts_with?(key, &1))
    end)
  end

  @doc "The settings at `key` and under it."
  @spec slice(t(), String.t()) :: t()
  def slice(settings, key) do
    Map.filter(settings, fn {name, _value} -> under?(name, key) end)
  end

  @doc "`value` (a scalar, a map or `nil`) as flat settings at `key`."
  @spec at(String.t(), term()) :: t()
  def at(_key, nil), do: %{}

  def at(key, %{} = value) when not is_struct(value) do
    value |> flatten("") |> Map.new(fn {name, value} -> {key <> "." <> name, value} end)
  end

  def at(key, value), do: %{key => value}

  @doc "Replaces what `settings` holds at `key` with `value`."
  @spec put(t(), String.t(), term()) :: t()
  def put(settings, key, value) do
    settings |> delete(key) |> Map.merge(at(key, value))
  end

  @doc "Removes `key` and everything under it."
  @spec delete(t(), String.t()) :: t()
  def delete(settings, key) do
    Map.reject(settings, fn {name, _value} -> under?(name, key) end)
  end

  @doc "Whether two sets of settings are equal, as the engine stores them (strings)."
  @spec same?(t(), t()) :: boolean()
  def same?(left, right), do: normalize(left) == normalize(right)

  defp normalize(settings), do: Map.new(settings, fn {key, value} -> {key, scalar(value)} end)

  defp scalar(list) when is_list(list), do: Enum.map(list, &scalar/1)
  defp scalar(nil), do: nil
  defp scalar(value) when is_float(value), do: Float.to_string(value)
  defp scalar(value), do: to_string(value)

  @doc """
  The body of a settings update turning `from` into `to`: what changed, and
  `nil` for what was removed — as `index.`-prefixed flat keys.
  """
  @spec diff(t(), t()) :: map()
  def diff(from, to) do
    changed = Map.reject(to, fn {key, value} -> same?(Map.take(from, [key]), %{key => value}) end)
    removed = from |> Map.drop(Map.keys(to)) |> Map.new(fn {key, _value} -> {key, nil} end)

    changed |> Map.merge(removed) |> body()
  end

  @doc "Flat settings as a request body: `index.`-prefixed keys."
  @spec body(t()) :: map()
  def body(settings), do: Map.new(settings, fn {key, value} -> {"index." <> key, value} end)

  defp under?(name, key), do: name == key or String.starts_with?(name, key <> ".")
end
