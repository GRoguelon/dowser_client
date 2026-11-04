defmodule Dowser.Mapping do
  @moduledoc """
  Where a mapping comes from — the behaviour behind the `:mapping` option.

  Casting needs the mapping of the index a document belongs to. By default a
  backend package asks the cluster, through its mapping cacher
  (`Dowser.OpenSearch.MappingCacher`, `Dowser.Elasticsearch.MappingCacher`),
  which implements this behaviour. `:mapping` names another source:

    * a map — the mapping itself, whatever the index;
    * a module implementing this behaviour — mappings read from files, from
      another cache, built at runtime…;
    * a document module (see `Dowser.Schema`) — its own mapping, with no
      request to the cluster.

  ## Implementing it

      defmodule MyApp.Mappings do
        @behaviour Dowser.Mapping

        @impl true
        def fetch_mapping("posts" <> _rest, _repo_config), do: {:ok, MyApp.Mappings.Posts.mapping()}
        def fetch_mapping(_index, _repo_config), do: {:ok, nil}
      end

  `index` is the index a document came from, or the one a request writes to —
  `nil` when there is none. `repo_config` is the request's repo, resolved; use
  it to tell clusters apart.

  Return `{:ok, mapping}`, `{:ok, nil}` when there is no mapping to be had (the
  document is then left as it is), or `{:error, reason}` when the mapping
  exists but couldn't be fetched — which `:mapping_failure` then decides about.
  """

  @doc "Returns the mapping of `index` on the repo `repo_config` resolves to."
  @callback fetch_mapping(index :: String.t() | nil, repo_config :: Dowser.Repo.Config.t()) ::
              {:ok, map() | nil} | {:error, term()}
end
