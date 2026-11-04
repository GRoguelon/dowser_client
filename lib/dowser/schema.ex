defmodule Dowser.Schema do
  @moduledoc """
  A document module — the behaviour behind the `:struct` option.

  `struct: PostDocument` loads every document of a response into a
  `%PostDocument{}`, and dumps one back, using the module's own mapping rather
  than the cluster's. A document module implements three callbacks:

    * `c:__schema__/1` — `__schema__(:mapping)` is its mapping, in the shape
      the cluster returns it (string keys, `"properties"`);
    * `c:__load__/2` — turns one `_source` into the struct;
    * `c:__dump__/2` — turns the struct back into a source.

  The backend packages' `use ...Schema` generates all three from a schema
  definition. Implementing them by hand works too, and is what the generated
  code does in the end:

      defmodule MyApp.Post do
        @behaviour Dowser.Schema

        defstruct [:title, :published_at]

        @mapping %{
          "properties" => %{
            "title" => %{"type" => "text"},
            "published_at" => %{"type" => "date", "format" => "strict_date_time"}
          }
        }

        @impl true
        def __schema__(:mapping), do: @mapping

        @impl true
        def __load__(source, opts) do
          source = Dowser.Source.load(source, @mapping, opts)

          %__MODULE__{title: source["title"], published_at: source["published_at"]}
        end

        @impl true
        def __dump__(%__MODULE__{} = post, opts) do
          Dowser.Source.dump(Map.from_struct(post), @mapping, opts)
        end
      end

  `opts` carry the casting in play — `:types`, `:opaque`, `:unknown_fields` —
  and, when loading, `:meta`: the document's metadata (`"_id"`, `"_index"`,
  `"_version"`, `"_seq_no"`, `"_primary_term"`, `"_score"`, `"sort"`,
  `"_routing"`, whichever the response has).

  They don't carry `:key_fn`. The `:keys` option casts the keys of *maps* —
  the response envelope around the struct, and documents loaded as maps — so a
  loader always reads its source by the mapping's string names, whatever
  `:keys` the request uses.

  A document module is also a mapping source: `mapping: MyApp.Post` casts
  documents with its mapping, but leaves them maps.
  """

  @doc "`:mapping` — the module's mapping."
  @callback __schema__(:mapping) :: map()

  @doc "Loads one document source into the module's struct."
  @callback __load__(source :: map(), opts :: keyword()) :: struct()

  @doc "Dumps the module's struct — or a map of its fields — back into a source."
  @callback __dump__(document :: struct() | map(), opts :: keyword()) :: map()

  @doc """
  Whether `module` is a document module: one implementing this behaviour.
  """
  @spec schema?(term()) :: boolean()
  def schema?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and
      function_exported?(module, :__load__, 2) and function_exported?(module, :__dump__, 2)
  end

  def schema?(_term), do: false
end
