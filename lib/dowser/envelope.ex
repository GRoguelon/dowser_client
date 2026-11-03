defmodule Dowser.Envelope do
  @moduledoc """
  Finds the documents in a response body, at any depth, and casts each one
  with `Dowser.Source` against its own index's mapping.

  A document is a map with a string `"_index"` and a map `"_source"`: a bare
  document (a `GET /{index}/_doc/{id}`), each of `hits.hits[]` (a search),
  `responses[].hits.hits[]` (a multi-search), `docs[]` (a multi-get), and so
  on. Each one's `"_index"` selects its mapping, so a mixed-index result is
  cast correctly.

  A hit's `inner_hits` are cast too. They carry no `_index` of their own, so
  their mapping comes from the hit they belong to: `_nested.field` names the
  path into it, and an inner hit with no `_nested` (a `has_child` or
  `has_parent` join) is cast against the index mapping itself. The rest of a
  hit's envelope — `fields`, `highlight`, `sort` — has no mapping entry to be
  cast against, and only has its keys run through `:key_fn`.

  Everything around the documents is envelope too: its keys go through
  `:key_fn`, its values are left alone.
  """

  alias Dowser.CoreExt.Keyable

  ## Public functions

  @doc """
  Casts every document found in `body`.

  `mapping_fn` returns the mapping for an index name (`nil` when there is
  none). `opts` are `Dowser.Source`'s: `:key_fn` (default: identity), `:type`
  and `:opaque`.

      iex> mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}
      iex> body = %{"hits" => %{"hits" => [%{"_index" => "hosts", "_source" => %{"ip" => "127.0.0.1"}}]}}
      iex> Dowser.Envelope.load(body, fn "hosts" -> mapping end)
      %{"hits" => %{"hits" => [%{"_index" => "hosts", "_source" => %{"ip" => {127, 0, 0, 1}}}]}}
  """
  @spec load(term(), (term() -> map() | nil), keyword()) :: term()
  def load(body, mapping_fn, opts \\ []) when is_function(mapping_fn, 1) do
    opts = Keyword.put_new(opts, :key_fn, &Function.identity/1)

    walk(body, mapping_fn, opts)
  end

  ## Private functions — the envelope

  defp walk(%{"_index" => <<_::binary>> = index, "_source" => %{}} = hit, mapping_fn, opts) do
    hit(hit, mapping_fn.(index), opts)
  end

  defp walk(%{} = map, mapping_fn, opts) when not is_struct(map) do
    key_fn = Keyword.fetch!(opts, :key_fn)

    Map.new(map, fn {key, value} ->
      {key_fn.(key), walk(value, mapping_fn, opts)}
    end)
  end

  defp walk(list, mapping_fn, opts) when is_list(list) do
    Enum.map(list, &walk(&1, mapping_fn, opts))
  end

  defp walk(value, _mapping_fn, _opts) do
    value
  end

  defp hit(hit, mapping, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)

    Map.new(hit, fn
      {"_source" = key, source} ->
        {key_fn.(key), Dowser.Source.load(source, mapping, opts)}

      # `inner_hits` holds documents rather than envelope: each named entry is
      # a hits envelope of its own, over documents of the same index. They
      # carry no `_index` to resolve a mapping from — `_nested.field` names
      # the path into this hit's mapping instead.
      {"inner_hits" = key, value} ->
        {key_fn.(key), inner_hits(value, mapping, opts)}

      # The rest of a hit is envelope, not document: `fields`, `highlight` and
      # friends. Their keys follow the same `:keys` as the rest of the
      # response, or a caller reading `hit.fields` would find a string-keyed
      # map inside an otherwise atom-keyed one.
      {key, value} ->
        {key_fn.(key), Keyable.transform_keys(value, key_fn)}
    end)
  end

  ## Private functions — inner hits

  # `%{name => hits envelope}`. The names come from the query that asked for
  # them, so they are keyed like the rest of the response.
  defp inner_hits(%{} = value, mapping, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)

    Map.new(value, fn {name, result} ->
      {key_fn.(name), inner_result(result, mapping, opts)}
    end)
  end

  defp inner_hits(value, _mapping, opts) do
    Keyable.transform_keys(value, Keyword.fetch!(opts, :key_fn))
  end

  defp inner_result(%{"hits" => %{"hits" => hits} = envelope} = result, mapping, opts)
       when is_list(hits) do
    key_fn = Keyword.fetch!(opts, :key_fn)
    hits = Enum.map(hits, &inner_hit(&1, mapping, opts))
    envelope = envelope |> Map.delete("hits") |> Keyable.transform_keys(key_fn)

    result
    |> Map.delete("hits")
    |> Keyable.transform_keys(key_fn)
    |> Map.put(key_fn.("hits"), Map.put(envelope, key_fn.("hits"), hits))
  end

  defp inner_result(result, _mapping, opts) do
    Keyable.transform_keys(result, Keyword.fetch!(opts, :key_fn))
  end

  defp inner_hit(%{"_source" => %{}} = hit, mapping, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)
    inner_mapping = nested_mapping(mapping, Map.get(hit, "_nested"))

    Map.new(hit, fn
      {"_source" = key, value} ->
        {key_fn.(key), Dowser.Source.load(value, inner_mapping, opts)}

      # A `_nested` chain is written from the root of the document, so a
      # deeper level of inner hits resolves against the same mapping.
      {"inner_hits" = key, value} ->
        {key_fn.(key), inner_hits(value, mapping, opts)}

      {key, value} ->
        {key_fn.(key), Keyable.transform_keys(value, key_fn)}
    end)
  end

  defp inner_hit(hit, _mapping, opts) do
    Keyable.transform_keys(hit, Keyword.fetch!(opts, :key_fn))
  end

  # Walks a `_nested` chain — `%{"field" => path, "_nested" => %{...}}`, each
  # link a path relative to the one above — down to the mapping entry of the
  # nested document the inner hit came from. An inner hit with no `_nested`
  # (a `has_child`/`has_parent` join) is a document of the index itself, and
  # keeps the mapping it was given. A path the mapping doesn't know degrades
  # to no mapping, and so to no cast.
  defp nested_mapping(mapping, %{"field" => <<_::binary>> = field} = nested) do
    case field_mapping(mapping, field) do
      nil ->
        nil

      inner_mapping ->
        nested_mapping(inner_mapping, Map.get(nested, "_nested"))
    end
  end

  defp nested_mapping(mapping, _nested) do
    mapping
  end

  defp field_mapping(mapping, path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(mapping, &field_step/2)
  end

  defp field_step(segment, %{"properties" => properties}) do
    case Map.fetch(properties, segment) do
      {:ok, field} ->
        {:cont, field}

      :error ->
        {:halt, nil}
    end
  end

  defp field_step(_segment, _mapping) do
    {:halt, nil}
  end
end
