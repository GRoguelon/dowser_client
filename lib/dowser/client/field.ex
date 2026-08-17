defmodule Dowser.Client.Field do
  @moduledoc """
  Behaviour for casting a single value to and from its wire representation.

  A `Dowser.Client.Field` knows how to cast *one* backend field type — a date, a
  geo point, an IP, whatever a backend's mapping describes — in both
  directions:

    * `load/2` — turns a decoded-but-still-raw value (e.g. the string
      `"2024-01-01"`) into a richer Elixir term (e.g. `~D[2024-01-01]`).
    * `dump/2` — the reverse, turning a richer term back into whatever the
      backend expects on the wire.

  Both callbacks receive the value and a second argument — typically the
  field's own metadata (e.g. an Elasticsearch mapping entry) — and return the
  cast term directly. A value the field doesn't recognize should pass through
  unchanged rather than raise, so a bad cast degrades to identity instead of
  failing the whole document.

  `dowser_client` ships only this behaviour, not any implementation — it has
  no knowledge of any particular backend's field types. A backend package
  (e.g. `dowser_elasticsearch`) implements one module per field type and
  wires them together with `Dowser.Client.Codec.Builder`, which assembles a
  `load/2`/`dump/2` dispatcher from them — see its moduledoc for how that
  dispatcher is then wired into a `Dowser.Client.Codec` as `:codec_adapter`.

      defmodule MyApp.Fields.Date do
        @behaviour Dowser.Client.Field

        @impl true
        def load(value, %{"format" => "strict_date"}) when is_binary(value) do
          case Date.from_iso8601(value) do
            {:ok, date} -> date
            {:error, _reason} -> value
          end
        end

        def load(value, _field), do: value

        @impl true
        def dump(%Date{} = date, %{"format" => "strict_date"}) do
          Date.to_iso8601(date)
        end

        def dump(value, _field), do: value
      end
  """

  ## Behaviour callbacks

  @doc "Casts `value` from its wire representation into a richer term."
  @callback load(value :: term(), field :: term()) :: term()

  @doc "Casts `value` back into its wire representation."
  @callback dump(value :: term(), field :: term()) :: term()
end
