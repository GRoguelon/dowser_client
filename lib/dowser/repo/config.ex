defmodule Dowser.Repo.Config do
  @moduledoc """
  A repo's configuration, resolved: the `:endpoint` to talk to, the `:auth` to
  send, the `:httpc` profile to send through, and how to cast the responses it
  returns.

  It is what every `:repo` resolves into before a request is built — a repo
  module, one of its dynamic instances, or the attributes of an ad-hoc repo:

      Dowser.Client.get("/_cluster/health", repo: [endpoint: "http://localhost:9200"])

  `MyApp.Search.config/0` returns the one a repo is using, and a decoder or
  encoder receives it as `:repo_config`.

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
      defaults it to the name it was started under (the repo module itself,
      unless it is a dynamic instance); an ad-hoc repo to `:dowser_client`.
      See `Dowser.Client.HTTP.Profile`.
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

  ## Public functions

  @struct ~w[endpoint auth profile profile_opts http_opts keys decoder encoder]a

  @doc """
  Builds a configuration from a map or keyword list, ignoring keys that aren't
  fields.

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
  Resolves anything a `:repo` option accepts into a `%Dowser.Repo.Config{}`:

    * a repo module — the configuration of the instance the calling process
      uses: its dynamic repo if it set one (`put_dynamic_repo/1`), the repo
      itself otherwise;
    * `{repo, name}` — the configuration of that repo's instance started as
      `name`, whatever the calling process uses;
    * a map or keyword list — an ad-hoc repo, built via `new/1`;
    * a `%Dowser.Repo.Config{}` — returned as-is.

  `nil` is no repo at all: `dowser_client` has no default, and each backend
  package supplies its own (`config :dowser_opensearch, default_repo: ...`).

  A repo whose configuration can't be resolved — no `:endpoint`, a dynamic
  instance that isn't started — is reported as
  `{:error, {:invalid_repo, repo, message}}`.
  """
  @spec resolve(Dowser.Repo.t() | nil) ::
          {:ok, t()}
          | {:error, :no_repo | {:unknown_repo, term()} | {:invalid_repo, term(), String.t()}}
  def resolve(repo)

  def resolve(%__MODULE__{} = config) do
    {:ok, config}
  end

  def resolve(nil) do
    {:error, :no_repo}
  end

  def resolve(repo) when is_atom(repo) do
    resolve_repo(repo, repo)
  end

  def resolve({repo, name} = instance) when is_atom(repo) and is_atom(name) do
    resolve_repo(repo, instance)
  end

  def resolve(config) when is_list(config) or is_map(config) do
    {:ok, new(config)}
  end

  def resolve(other) do
    {:error, {:unknown_repo, other}}
  end

  defp resolve_repo(repo, ref) do
    if Dowser.Repo.repo?(repo) do
      {:ok, Dowser.Repo.config(ref)}
    else
      {:error, {:unknown_repo, ref}}
    end
  rescue
    exception in ArgumentError ->
      {:error, {:invalid_repo, ref, Exception.message(exception)}}
  end
end

defimpl Inspect, for: Dowser.Repo.Config do
  @moduledoc false

  def inspect(config, opts) do
    config
    |> Map.from_struct()
    |> Map.update!(:auth, &redact/1)
    |> Inspect.Algebra.to_doc(opts)
    |> then(&Inspect.Algebra.concat(["#Dowser.Repo.Config<", &1, ">"]))
  end

  defp redact(nil), do: nil

  defp redact(auth) when is_tuple(auth) and tuple_size(auth) > 0 do
    put_elem(auth, tuple_size(auth) - 1, "[FILTERED]")
  end

  defp redact(_auth), do: "[FILTERED]"
end
