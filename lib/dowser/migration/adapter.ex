defmodule Dowser.Migration.Adapter do
  @moduledoc """
  What `Dowser.Migrator` needs from a backend package to run migrations
  against its engine: the cluster requests, and where it keeps which
  migrations ran.

  A backend's repo names its adapter — `use Dowser.OpenSearch.Repo` defines
  `__migration_adapter__/0` — so an application never names one.

  Every callback takes the repo to send the request to (anything a `:repo`
  option takes) and returns `:ok`/`{:ok, result}` or `{:error, reason}`.
  Index names are physical indices unless a callback says otherwise; settings
  are flat and `index.`-prefixed (`"index.number_of_replicas"`), mappings and
  bodies have string keys.

  `use Dowser.Migration.Adapter` gives a default `c:dynamic_setting?/1`.

  ## Tracking

  The adapter keeps one record per migration run — `%{"version" => integer,
  "name" => string, "indices" => [string], "dropped" => [string],
  "separators" => %{index => string}}`, given and returned as they are — and one
  lock: a document only one migrator can create, holding `"owner"` and
  `"state"` — what a copy in progress has changed, for `mix dowser.recover`
  after a crash.
  """

  alias Dowser.Migration.Settings

  @type repo :: Dowser.Repo.t()
  @type result :: :ok | {:error, term()}

  @typedoc """
  An index as `c:get_indices/2` returns it: `"mappings"`, `"settings"` (flat,
  without the `index.` prefix) and `"aliases"` (names).
  """
  @type index :: %{String.t() => term()}

  @doc "Creates what tracking needs (its index) when missing."
  @callback ensure_tracking(repo()) :: result()

  @doc "The migrations recorded as run, in any order."
  @callback applied(repo()) :: {:ok, [map()]} | {:error, term()}

  @doc "Records a migration as run."
  @callback record(repo(), record :: map()) :: result()

  @doc "Removes a migration's record."
  @callback unrecord(repo(), version :: integer()) :: result()

  @doc """
  Takes the lock, creating it with `lock`; `{:error, {:locked, lock}}` with
  the one in place when another migrator holds it.
  """
  @callback lock(repo(), lock :: map()) :: result()

  @doc "The lock in place, or `nil`."
  @callback get_lock(repo()) :: {:ok, map() | nil} | {:error, term()}

  @doc "Replaces the lock's content."
  @callback update_lock(repo(), lock :: map()) :: result()

  @doc "Releases the lock."
  @callback unlock(repo()) :: result()

  @doc """
  The indices matching `names` — aliases, index names or patterns — keyed by
  physical name; none for a name matching nothing.
  """
  @callback get_indices(repo(), names :: [String.t()]) ::
              {:ok, %{String.t() => index()}} | {:error, term()}

  @doc "Creates an index from a create-index request `body`."
  @callback create_index(repo(), index :: String.t(), body :: map()) :: result()

  @doc "Deletes an index."
  @callback delete_index(repo(), index :: String.t()) :: result()

  @doc "Adds fields — and replaces `_meta` — with a put-mapping request `body`."
  @callback put_mapping(repo(), index :: String.t(), body :: map()) :: result()

  @doc "Updates settings; a `nil` value resets one."
  @callback put_settings(repo(), index :: String.t(), settings :: map()) :: result()

  @doc """
  Blocks writes to an index, once the writes in flight are done (the
  add-block API, not the setting).
  """
  @callback add_write_block(repo(), index :: String.t()) :: result()

  @doc "Lifts an index's write block."
  @callback remove_write_block(repo(), index :: String.t()) :: result()

  @doc "Moves alias `name` from index `from` to index `to`, atomically."
  @callback swap_alias(repo(), name :: String.t(), from :: String.t(), to :: String.t()) ::
              result()

  @doc """
  Starts copying `source` into `dest` in the background, through `script`
  when not `nil`; returns the task's id.
  """
  @callback reindex(repo(), source :: String.t(), dest :: String.t(), script :: map() | nil) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  A background task's status, as the tasks API returns it: `"completed"`,
  then `"response"` (with `"failures"`, `"total"`, `"created"`) or `"error"`.
  """
  @callback get_task(repo(), task :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Whether the engine changes setting `key` (relative to `index`) on a live
  index; anything else is changed by copying the documents.
  """
  @callback dynamic_setting?(key :: String.t()) :: boolean()

  @doc false
  # The settings the engines change on a live index; see `Dowser.Migration.Settings`.
  @spec default_dynamic_setting?(String.t()) :: boolean()
  def default_dynamic_setting?(key), do: Settings.dynamic?(key)

  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def dynamic_setting?(key), do: unquote(__MODULE__).default_dynamic_setting?(key)

      defoverridable dynamic_setting?: 1
    end
  end
end
