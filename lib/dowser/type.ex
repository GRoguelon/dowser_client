defmodule Dowser.Type do
  @moduledoc """
  Field types: casting **one value** between its JSON representation and an
  Elixir term, given the mapping entry that describes it.

  A type knows nothing about where the value sits in a document — objects,
  nested fields and arrays are `Dowser.Source`'s business, which hands each
  leaf value here with its own mapping entry (`field`). This module is both the
  behaviour every type implements and the default dispatcher over the built-in
  ones, selected by the entry's `"type"`:

  | mapping type           | type module              | Elixir term                   |
  | ---------------------- | ------------------------ | ----------------------------- |
  | `date`, `date_nanos`   | `Dowser.Type.Date`       | `Date`, `Time`, `DateTime`, `NaiveDateTime` (by `"format"`) |
  | `date_range`           | `Dowser.Type.DateRange`  | `Date.Range` (`strict_date` only) |
  | `integer_range`, `long_range` | `Dowser.Type.Range` | `Range`                     |
  | `ip`                   | `Dowser.Type.IP`         | `:inet` tuple                 |
  | `binary`               | `Dowser.Type.Binary`     | raw binary                    |
  | `geo_point`            | `Dowser.Type.GeoPoint`   | `{lat, lon}`                  |

  Only the types JSON can't represent natively are cast; any other entry —
  like a `nil` value — falls back to identity.

      iex> Dowser.Type.load("127.0.0.1", %{"type" => "ip"})
      {127, 0, 0, 1}

      iex> Dowser.Type.dump({127, 0, 0, 1}, %{"type" => "ip"})
      "127.0.0.1"

  ## The behaviour

  `load/2` and `dump/2` take one value and the mapping entry describing it, and
  return the cast term. A value a type doesn't recognize should pass through
  unchanged rather than raise, so a bad cast degrades to identity instead of
  failing the whole document.

  ## Adding types

  A type module is a plain module, so covering one more type is a clause per
  direction and a delegation back here for everything else:

      defmodule MyApp.Type do
        @behaviour Dowser.Type

        @impl true
        def load(value, %{"type" => "scaled_float", "scaling_factor" => factor})
            when is_integer(value) do
          value / factor
        end

        def load(value, field), do: Dowser.Type.load(value, field)

        @impl true
        def dump(value, %{"type" => "scaled_float", "scaling_factor" => factor})
            when is_float(value) do
          round(value * factor)
        end

        def dump(value, field), do: Dowser.Type.dump(value, field)
      end

  Delegating last inherits the built-in casts — including the `nil`
  short-circuit and the fall-through to identity. Matching a type this module
  already handles *replaces* that cast, since your clause comes first. A
  backend package's codec takes such a module as its `:codec` option.
  """

  ## Behaviour callbacks

  @doc "Casts `value` from its JSON representation into a richer term."
  @callback load(value :: term(), field :: map()) :: term()

  @doc "Casts `value` back into its JSON representation."
  @callback dump(value :: term(), field :: map()) :: term()

  @behaviour __MODULE__

  ## Module attributes

  @types %{
    "binary" => Dowser.Type.Binary,
    "date" => Dowser.Type.Date,
    "date_nanos" => Dowser.Type.Date,
    "date_range" => Dowser.Type.DateRange,
    "geo_point" => Dowser.Type.GeoPoint,
    "integer_range" => Dowser.Type.Range,
    "ip" => Dowser.Type.IP,
    "long_range" => Dowser.Type.Range
  }

  ## Public functions

  @doc """
  Casts `value` from its JSON representation, dispatching on `field`'s
  `"type"`.

  A `nil` value, a mapping entry with no known `"type"`, or no mapping entry at
  all, all return `value` untouched.
  """
  @impl true
  def load(value, field)

  def load(nil, _field), do: nil

  def load(value, %{"type" => type} = field) do
    case Map.fetch(@types, type) do
      {:ok, module} ->
        module.load(value, field)

      :error ->
        value
    end
  end

  def load(value, _field), do: value

  @doc """
  Casts `value` back into its JSON representation, dispatching on `field`'s
  `"type"`.

  The mirror image of `load/2`, with the same fallbacks.
  """
  @impl true
  def dump(value, field)

  def dump(nil, _field), do: nil

  def dump(value, %{"type" => type} = field) do
    case Map.fetch(@types, type) do
      {:ok, module} ->
        module.dump(value, field)

      :error ->
        value
    end
  end

  def dump(value, _field), do: value
end
