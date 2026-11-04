defmodule Dowser.Source do
  @moduledoc """
  Walks one document source against its mapping: the **structure** half of
  casting, as `Dowser.Type` is the value half.

  What a value is depends on its mapping entry, never on its shape:

    * an entry with `"properties"`, or of type `object`/`nested`, is an
      **object** — a map is walked key by key against those properties, a list
      element by element, and on the way out a struct is turned into a map
      first;
    * an entry of an **opaque** type (`opts[:opaque]`, the backend's
      `flat_object`/`flattened`), or one mapped `"enabled": false`, holds
      whatever the document put in it: it is returned exactly as it is;
    * any other entry with a `"type"` is a **leaf** — the whole value goes to
      the type module (`opts[:types]`), even when it is a map (a range, a
      `geo_point` object), and an array of them element by element;
    * no entry at all (a field the mapping doesn't know) is left as it is,
      only its keys going through `opts[:key_fn]` on the way in — or, with
      `unknown_fields: :raise`, raises a `Dowser.UnknownFieldError`.

  A leaf whose type left a map uncast (no type for it, or a shape it didn't
  recognize) has its keys go through `opts[:key_fn]` like the rest of the
  document. An opaque subtree's keys never do: they are document content, not
  mapping names, and under `keys: :atoms` would turn any writer into a way to
  exhaust the atom table.

  ## Options

    * `:key_fn` — applied to every key `load/3` walks (default: identity).
    * `:types` — the `Dowser.Type` module leaves are cast through (default
      `Dowser.Type`).
    * `:opaque` — the mapping types whose subtree is left alone (default `[]`).
    * `:unknown_fields` — what to do with a field an object's `"properties"`
      don't declare: `:keep` it as it is (default), or `:raise` a
      `Dowser.UnknownFieldError`. With no mapping at all, nothing is unknown.
  """

  alias Dowser.CoreExt.Keyable
  alias Dowser.UnknownFieldError

  ## Public functions

  @doc """
  Casts `source` from its JSON representation against `mapping`.

      iex> mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}
      iex> Dowser.Source.load(%{"ip" => "127.0.0.1"}, mapping, key_fn: &String.to_atom/1)
      %{ip: {127, 0, 0, 1}}
  """
  @spec load(term(), map() | nil, keyword()) :: term()
  def load(source, mapping, opts \\ []) do
    do_load(source, mapping, config(opts, :load), [])
  end

  @doc """
  Casts `source` back into its JSON representation against `mapping`. Keys are
  kept as given.

      iex> mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}
      iex> Dowser.Source.dump(%{ip: {127, 0, 0, 1}}, mapping)
      %{ip: "127.0.0.1"}
  """
  @spec dump(term(), map() | nil, keyword()) :: term()
  def dump(source, mapping, opts \\ []) do
    do_dump(source, mapping, config(opts, :dump), [])
  end

  ## Private functions — classification

  defp config(opts, direction) do
    %{
      key_fn: Keyword.get(opts, :key_fn, &Function.identity/1),
      types: Keyword.get(opts, :types) || Dowser.Type,
      opaque: Keyword.get(opts, :opaque, []),
      unknown_fields: Keyword.get(opts, :unknown_fields) || :keep,
      direction: direction
    }
  end

  defp kind(%{"enabled" => false}, _config), do: :opaque
  defp kind(%{"type" => type}, _config) when type in ["object", "nested"], do: :object

  defp kind(%{"type" => type}, config) do
    if type in config.opaque, do: :opaque, else: :leaf
  end

  defp kind(%{"properties" => _properties}, _config), do: :object
  defp kind(_entry, _config), do: :unknown

  # A field an object's properties don't declare: `nil` — no mapping entry —
  # unless the caller asked to hear about it.
  defp field(properties, key, config, path) do
    case Map.fetch(properties, to_string(key)) do
      {:ok, entry} ->
        entry

      :error when config.unknown_fields == :raise ->
        raise UnknownFieldError, path: path ++ [to_string(key)], direction: config.direction

      :error ->
        nil
    end
  end

  ## Private functions — load

  defp do_load(nil, _entry, _config, _path) do
    nil
  end

  defp do_load(value, entry, config, path) do
    case kind(entry, config) do
      :object ->
        load_object(value, entry, config, path)

      :leaf ->
        load_leaf(value, entry, config)

      :opaque ->
        value

      :unknown ->
        Keyable.transform_keys(value, config.key_fn)
    end
  end

  defp load_object(values, entry, config, path) when is_list(values) do
    Enum.map(values, &do_load(&1, entry, config, path))
  end

  defp load_object(%{} = value, entry, config, path) when not is_struct(value) do
    properties = Map.get(entry, "properties", %{})

    Map.new(value, fn {key, value} ->
      field = field(properties, key, config, path)

      {config.key_fn.(key), do_load(value, field, config, path ++ [to_string(key)])}
    end)
  end

  defp load_object(value, _entry, _config, _path) do
    value
  end

  defp load_leaf(values, entry, config) when is_list(values) do
    Enum.map(values, &load_leaf(&1, entry, config))
  end

  defp load_leaf(nil, _entry, _config) do
    nil
  end

  defp load_leaf(value, entry, config) do
    case config.types.load(value, entry) do
      %{} = map when not is_struct(map) ->
        Keyable.transform_keys(map, config.key_fn)

      loaded ->
        loaded
    end
  end

  ## Private functions — dump

  defp do_dump(nil, _entry, _config, _path) do
    nil
  end

  defp do_dump(value, entry, config, path) do
    case kind(entry, config) do
      :object ->
        dump_object(value, entry, config, path)

      :leaf ->
        dump_leaf(value, entry, config)

      _opaque_or_unknown ->
        value
    end
  end

  defp dump_object(values, entry, config, path) when is_list(values) do
    Enum.map(values, &do_dump(&1, entry, config, path))
  end

  defp dump_object(%MapSet{} = values, entry, config, path) do
    MapSet.new(values, &do_dump(&1, entry, config, path))
  end

  defp dump_object(%_{} = struct, entry, config, path) do
    struct
    |> Map.from_struct()
    |> dump_object(entry, config, path)
  end

  defp dump_object(%{} = value, entry, config, path) do
    properties = Map.get(entry, "properties", %{})

    Map.new(value, fn {key, value} ->
      field = field(properties, key, config, path)

      {key, do_dump(value, field, config, path ++ [to_string(key)])}
    end)
  end

  defp dump_object(value, _entry, _config, _path) do
    value
  end

  defp dump_leaf(values, entry, config) when is_list(values) do
    Enum.map(values, &dump_leaf(&1, entry, config))
  end

  defp dump_leaf(%MapSet{} = values, entry, config) do
    MapSet.new(values, &dump_leaf(&1, entry, config))
  end

  defp dump_leaf(value, entry, config) do
    config.types.dump(value, entry)
  end
end
