defmodule Dowser.Client.Context do
  @moduledoc """
  One search backend to talk to: its `:endpoint`, `:auth`, the `:httpc` profile
  to send through, and how to cast the responses it returns.

  The name follows `elastic/cli`'s notion of a *context* — a named cluster you
  address by name instead of repeating its coordinates at every call site.

  Build one inline with `new/1`, or configure named ones at compile time:

      config :dowser_client,
        contexts: [
          default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}],
          logs: [endpoint: "https://logs.internal:9200", profile: :logs]
        ]

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
      backend its own connection pool and session settings. Defaults to
      `:dowser_client`; see `Dowser.Client.HTTP.Profile`.
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

  `resolve/1` — used by `Dowser.Client.request/4` on `opts[:context]` — turns
  any of the following into a `%Context{}`:

    * `nil` — resolves the `:default` entry from `config :dowser_client,
      contexts: [...]`. There is no built-in fallback; a `:default` entry must
      be configured, or every call site must pass `:context` explicitly.
    * an atom — looks up that name in the same `contexts` list/map.
    * a map or keyword list — builds an ad-hoc context inline via `new/1`.
    * a `%Context{}` — returned as-is.

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

  @typedoc "Anything `resolve/1` accepts: a context, a name, or attributes for `new/1`."
  @type ref :: t() | atom() | keyword() | map() | nil

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
  Resolves anything a `:context` option accepts into a `%Context{}`.

  See the module documentation for what each shape means.
  """
  @spec resolve(ref()) :: {:ok, t()} | {:error, {:unknown_context, atom()}}
  def resolve(context)

  def resolve(%__MODULE__{} = context) do
    {:ok, context}
  end

  def resolve(nil) do
    resolve(:default)
  end

  def resolve(name) when is_atom(name) and not is_nil(name) do
    case fetch(name) do
      {:ok, context} ->
        {:ok, context}

      :error ->
        {:error, {:unknown_context, name}}
    end
  end

  def resolve(context) when is_list(context) or is_map(context) do
    {:ok, new(context)}
  end

  @doc """
  Fetches the named context from `config :dowser_client, contexts: [...]`,
  returning `{:ok, %Context{}}` or `:error`.
  """
  @spec fetch(atom()) :: {:ok, t()} | :error
  def fetch(name) when is_atom(name) and not is_nil(name) do
    contexts = Application.get_env(:dowser_client, :contexts, %{})

    case fetch_entry(contexts, name) do
      {:ok, %__MODULE__{} = context} ->
        {:ok, context}

      {:ok, context} ->
        {:ok, new(context)}

      :error ->
        :error
    end
  end

  ## Private functions

  defp fetch_entry(contexts, name) when is_list(contexts) do
    Keyword.fetch(contexts, name)
  end

  defp fetch_entry(contexts, name) when is_map(contexts) do
    Map.fetch(contexts, name)
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
