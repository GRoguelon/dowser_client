defmodule Dowser.Client.Config do
  @moduledoc """
  Bundles everything needed to reach one search backend: its `:endpoint`,
  `:auth`, and the HTTP/JSON/codec adapters and options to use.

  Build one inline with `new/1`, or configure named ones at compile time:

      config :dowser_client,
        configs: [
          default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}],
          logs: [endpoint: "https://logs.internal:9200"]
        ]

  `resolve/1` — used by `Dowser.Client.request/4` on `opts[:config]` — turns
  any of the following into a `%Config{}`:

    * `nil` — resolves the `:default` entry from `config :dowser_client,
      configs: [...]`. There is no built-in fallback; a `:default` entry must
      be configured, or every call site must pass `:config` explicitly.
    * an atom — looks up that name in the same `configs` list/map.
    * a map or keyword list — builds an ad-hoc config inline via `new/1`.
    * a `%Config{}` — returned as-is.

  `:http_adapter`, `:json_adapter` and `:codec_adapter` default to `nil` on
  the struct itself; when unset, `Dowser.Client.Request` resolves them at
  request time from `config :dowser_client, :http_adapter | :json_adapter |
  :codec_adapter`, falling back to the built-in `Httpc`/`Native`/
  `Dowser.Client.Codec.Default` — so they can be changed at runtime (e.g. in
  `config/runtime.exs`), not just at compile time.
  """

  ## Structure

  @enforce_keys [:endpoint]
  defstruct endpoint: nil,
            auth: nil,
            http_adapter: nil,
            json_adapter: nil,
            http_opts: [],
            json_opts: [],
            codec_adapter: nil,
            codec_opts: [],
            keys: :strings

  ## Public functions

  @struct ~w[endpoint auth http_adapter json_adapter http_opts json_opts codec_adapter codec_opts keys]a

  def new(opts) when is_map(opts) do
    opts |> Map.take(@struct) |> then(&struct!(__MODULE__, &1))
  end

  def new(opts) when is_list(opts) do
    opts |> Map.new() |> new()
  end

  def resolve(%__MODULE__{} = config) do
    {:ok, config}
  end

  def resolve(nil) do
    resolve(:default)
  end

  def resolve(name) when is_atom(name) and not is_nil(name) do
    case fetch_configuration(name) do
      {:ok, config} ->
        {:ok, config}

      :error ->
        {:error, {:unknown_config, name}}
    end
  end

  def resolve(config) when is_list(config) or is_map(config) do
    {:ok, new(config)}
  end

  def fetch_configuration(name) when is_atom(name) and not is_nil(name) do
    configs = Application.get_env(:dowser_client, :configs, %{})

    case fetch_config_config(configs, name) do
      {:ok, %__MODULE__{} = config} ->
        {:ok, config}

      {:ok, config} ->
        {:ok, new(config)}

      :error ->
        :error
    end
  end

  ## Private functions

  defp fetch_config_config(configs, name) when is_list(configs) do
    Keyword.fetch(configs, name)
  end

  defp fetch_config_config(configs, name) when is_map(configs) do
    Map.fetch(configs, name)
  end
end

defimpl Inspect, for: Dowser.Client.Config do
  @moduledoc false

  def inspect(config, opts) do
    config
    |> Map.from_struct()
    |> Map.update!(:auth, &redact/1)
    |> Inspect.Algebra.to_doc(opts)
    |> then(&Inspect.Algebra.concat(["#Dowser.Client.Config<", &1, ">"]))
  end

  defp redact(nil), do: nil

  defp redact(auth) when is_tuple(auth) and tuple_size(auth) > 0 do
    put_elem(auth, tuple_size(auth) - 1, "[FILTERED]")
  end

  defp redact(_auth), do: "[FILTERED]"
end
