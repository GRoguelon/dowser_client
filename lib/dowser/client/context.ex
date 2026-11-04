defmodule Dowser.Client.Context do
  @moduledoc """
  One search backend to talk to, resolved: its `:endpoint`, `:auth`, the
  `:httpc` profile to send through, and how to cast the responses it returns.

  Applications don't build these by hand: they define a `Dowser.Repo` and pass
  it as the `:repo` option, and the repo resolves its configuration into a
  context. A script can pass the attributes of one directly instead:

      Dowser.Client.get("/_cluster/health", repo: [endpoint: "http://localhost:9200"])

  ## Fields

    * `:endpoint` — the backend's base URL (required).
    * `:auth` — credentials, applied as an `authorization` request header:

          {:basic, "dXNlcjpwYXNz"}          # Basic <value>, already encoded
          {:basic, "user", "changeme"}      # Basic <base64("user:changeme")>
          {:api_key, "VnVhQ2ZHY0..."}       # ApiKey <value>
          {:api_key, "id", "api_key"}       # ApiKey <base64("id:api_key")>
          {:bearer, "token"}                # Bearer <token>
          {:header, "x-custom-auth", "..."} # any header you like

    * `:profile` — the `:httpc` profile requests go through, giving this
      backend its own connection pool and session settings. A `Dowser.Repo`
      defaults it to the repo module itself; an ad-hoc context to
      `:dowser_client`. See `Dowser.Client.HTTP.Profile`.
    * `:profile_opts` — that profile's `:httpc.set_options/2` settings
      (`max_sessions`, `max_keep_alive_length`, `keep_alive_timeout`,
      `pipeline_timeout`, `cookies`, ...). Applied once, when the profile
      starts.
    * `:http_opts` — per-request transport options: `:headers`,
      `:connect_timeout`, `:timeout`, `:ssl`, ...; see `Dowser.Client.HTTP`.
    * `:keys` — `:strings` (default), `:atoms`, `:atoms!` or a function; how a
      decoded response body's keys are cast.
    * `:decoder` — a module exporting `decode/2`, a `(body, opts -> term)`
      function, or either paired with the options it needs
      (`{MyDecoder, mapping: mapping}`), owning the decoded response body: the
      backend package's own casting, whatever its envelope looks like. With
      neither `:keys` nor `:decoder` set, a response stays the plain,
      string-keyed term `Dowser.Client.JSON` produced. See
      `Dowser.Client.Decoder`.
    * `:encoder` — a module exporting `encode/2`, a `(source, opts -> term)`
      function, or either paired with the options it needs
      (`{MyEncoder, index: "articles"}`), casting a **document source** in a
      request body. It only runs when a request's `:encode` says where that
      source is; a query is never touched. See `Dowser.Client.Encoder`.

  `resolve/1` — used by `Dowser.Client.request/4` on `opts[:repo]` — turns
  any of the following into a `%Context{}`:

    * a repo module — its resolved configuration (`Dowser.Repo.context/1`);
    * a map or keyword list — an ad-hoc context, built via `new/1`;
    * a `%Context{}` — returned as-is.

  `nil` is no repo at all: `dowser_client` has no default, and each backend
  package supplies its own (`config :dowser_opensearch, default_repo: ...`).

  Every field but `:endpoint` defaults to `nil`/`[]` on the struct itself; when
  unset, `Dowser.Client.Request` resolves it at request time from
  `config :dowser_client, <the same key>`, falling back to the `:dowser_client`
  profile, string keys and no decoder — so they can be changed at runtime (e.g.
  in `config/runtime.exs`), not just at compile time.
  """

  ## Structure

  @enforce_keys [:endpoint]
  defstruct endpoint: nil,
            auth: nil,
            profile: nil,
            profile_opts: [],
            http_opts: [],
            keys: nil,
            decoder: nil,
            encoder: nil

  ## Typespecs

  @type auth ::
          {:basic, String.t()}
          | {:basic, String.t(), String.t()}
          | {:api_key, String.t()}
          | {:api_key, String.t(), String.t()}
          | {:bearer, String.t()}
          | {:header, String.t(), String.t()}

  @type t :: %__MODULE__{
          endpoint: String.t(),
          auth: auth() | nil,
          profile: Dowser.Client.HTTP.Profile.t() | nil,
          profile_opts: keyword(),
          http_opts: keyword(),
          keys: Dowser.Client.Decoder.keys() | nil,
          decoder: Dowser.Client.Decoder.decoder() | nil,
          encoder: Dowser.Client.Encoder.encoder() | nil
        }

  @typedoc "Anything `resolve/1` accepts: a context, a repo module, or attributes for `new/1`."
  @type ref :: t() | module() | keyword() | map() | nil

  ## Public functions

  @struct ~w[endpoint auth profile profile_opts http_opts keys decoder encoder]a

  @doc """
  Builds a context from a map or keyword list, ignoring keys that aren't fields.

  Raises `ArgumentError` when `:endpoint` is missing.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts)

  def new(opts) when is_map(opts) do
    opts |> Map.take(@struct) |> then(&struct!(__MODULE__, &1))
  end

  def new(opts) when is_list(opts) do
    opts |> Map.new() |> new()
  end

  @doc """
  Resolves anything a `:repo` option accepts into a `%Context{}`.

  See the module documentation for what each shape means. A repo module whose
  configuration can't be resolved (no `:endpoint`, say) is reported as
  `{:error, {:invalid_repo, repo, message}}`.
  """
  @spec resolve(ref()) ::
          {:ok, t()}
          | {:error, :no_repo | {:unknown_repo, atom()} | {:invalid_repo, module(), String.t()}}
  def resolve(repo)

  def resolve(%__MODULE__{} = context) do
    {:ok, context}
  end

  def resolve(nil) do
    {:error, :no_repo}
  end

  def resolve(repo) when is_atom(repo) do
    if Dowser.Repo.repo?(repo) do
      {:ok, Dowser.Repo.context(repo)}
    else
      {:error, {:unknown_repo, repo}}
    end
  rescue
    exception in ArgumentError ->
      {:error, {:invalid_repo, repo, Exception.message(exception)}}
  end

  def resolve(context) when is_list(context) or is_map(context) do
    {:ok, new(context)}
  end
end

defimpl Inspect, for: Dowser.Client.Context do
  @moduledoc false

  def inspect(context, opts) do
    context
    |> Map.from_struct()
    |> Map.update!(:auth, &redact/1)
    |> Inspect.Algebra.to_doc(opts)
    |> then(&Inspect.Algebra.concat(["#Dowser.Client.Context<", &1, ">"]))
  end

  defp redact(nil), do: nil

  defp redact(auth) when is_tuple(auth) and tuple_size(auth) > 0 do
    put_elem(auth, tuple_size(auth) - 1, "[FILTERED]")
  end

  defp redact(_auth), do: "[FILTERED]"
end
