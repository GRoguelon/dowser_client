defmodule Dowser.Type.Date do
  @moduledoc """
  `date` and `date_nanos` — ISO-8601 strings or epoch numbers <-> `Date`,
  `Time`, `DateTime` or `NaiveDateTime`, depending on the field's `"format"`.

  Each supported format maps onto the Elixir function that reads it:

  | format                                  | stored                            | Elixir                                    |
  | --------------------------------------- | --------------------------------- | ----------------------------------------- |
  | `epoch_millis`                          | `1553391286000`                   | `DateTime.from_unix(value, :millisecond)` |
  | `epoch_second`                          | `1553391286`                      | `DateTime.from_unix(value, :second)`      |
  | `strict_date`                           | `"2019-03-23"`                    | `Date.from_iso8601/1`                     |
  | `strict_date_hour_minute_second`        | `"2019-03-23T21:34:46"`           | `NaiveDateTime.from_iso8601/1`            |
  | `strict_date_hour_minute_second_millis` | `"2019-03-23T21:34:46.123"`       | `NaiveDateTime.from_iso8601/1`            |
  | `strict_date_time_no_millis`            | `"2019-03-23T21:34:46-04:00"`     | `DateTime.from_iso8601/1`                 |
  | `strict_date_time`                      | `"2019-03-23T21:34:46.123-04:00"` | `DateTime.from_iso8601/1`                 |
  | `strict_hour_minute_second`             | `"21:34:46"`                      | `Time.from_iso8601/1`                     |
  | `strict_hour_minute_second_millis`      | `"21:34:46.123"`                  | `Time.from_iso8601/1`                     |

  Any other format — including none at all, which the backend reads as
  `strict_date_optional_time||epoch_millis` — is not cast: its values are
  returned as they are stored, in both directions. So is a value its format
  can't read.

  A field with several supported formats (`"strict_date||epoch_millis"`)
  reads a value with the first of them that recognizes it, and writes with the
  first.

  ## Precision

  Reading takes a value at whatever precision it carries. Writing produces
  exactly the precision the format declares: a `DateTime`, `NaiveDateTime` or
  `Time` is truncated to the second for `strict_date_time_no_millis`,
  `strict_date_hour_minute_second`, `strict_hour_minute_second` and
  `epoch_second`, and to the millisecond — padded to three digits when it has
  fewer — for their `_millis` counterparts, `strict_date_time` and
  `epoch_millis`. A date-time written to `strict_date` keeps its date, and one
  written to a time-of-day format its time.

  ## Time zones

  A `DateTime` is always loaded as one UTC `DateTime`: an offset in the value
  (`-04:00`) is applied and then dropped, as `DateTime.from_iso8601/1` drops
  it. A value with no offset is read as UTC, as the backend reads it, and so
  is `-00:00` (RFC 3339's "UTC, local offset unknown", which
  `DateTime.from_iso8601/1` rejects). A `DateTime` in any other zone is dumped
  as its UTC instant, and a `NaiveDateTime` written to a format with an offset
  is taken to be UTC. So nothing here needs a time-zone database: the default
  `Calendar.UTCOnlyTimeZoneDatabase` and `tzdata` give the same results.

  The instant is exact — the backend stores dates as UTC milliseconds — but
  the original offset is not kept: a document written as
  `"2019-03-23T21:34:46-04:00"`, loaded and saved again, is written back as
  `"2019-03-24T01:34:46Z"`. Keep the zone in a field of its own, or write a
  `Dowser.Type` module for that field, where the local time matters.
  """

  ## Behaviours

  @behaviour Dowser.Type

  ## Module attributes

  @naive_formats %{
    "strict_date_hour_minute_second" => :second,
    "strict_date_hour_minute_second_millis" => :millisecond
  }

  @date_time_formats %{
    "strict_date_time_no_millis" => :second,
    "strict_date_time" => :millisecond
  }

  @time_formats %{
    "strict_hour_minute_second" => :second,
    "strict_hour_minute_second_millis" => :millisecond
  }

  @epoch_formats %{
    "epoch_second" => :second,
    "epoch_millis" => :millisecond
  }

  ## Public functions

  @impl true
  def load(value, %{"format" => format}) when is_binary(format) do
    format
    |> String.split("||")
    |> Enum.find_value(value, &do_load(value, &1))
  end

  def load(value, _field) do
    value
  end

  @impl true
  def dump(value, %{"format" => format}) when is_binary(format) do
    [format | _others] = String.split(format, "||")

    do_dump(value, format)
  end

  def dump(value, _field) do
    value
  end

  ## Private functions — load

  # Each clause returns the cast term, or `nil` when the value isn't one its
  # format reads — which `load/2` takes as "try the next format", and finally
  # as "return the value as stored".

  defp do_load(value, format) when is_map_key(@epoch_formats, format) and is_integer(value) do
    case DateTime.from_unix(value, Map.fetch!(@epoch_formats, format)) do
      {:ok, date_time} ->
        date_time

      {:error, _reason} ->
        nil
    end
  end

  defp do_load(value, "strict_date") when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        date

      {:error, _reason} ->
        nil
    end
  end

  defp do_load(value, format) when is_map_key(@naive_formats, format) and is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive_date_time} ->
        naive_date_time

      {:error, _reason} ->
        nil
    end
  end

  defp do_load(value, format) when is_map_key(@date_time_formats, format) and is_binary(value) do
    parse_date_time(value)
  end

  defp do_load(value, format) when is_map_key(@time_formats, format) and is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} ->
        time

      {:error, _reason} ->
        nil
    end
  end

  defp do_load(_value, _format) do
    nil
  end

  defp parse_date_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date_time, _offset} ->
        date_time

      # The backend reads a date-time with no offset as UTC.
      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive_date_time} ->
            DateTime.from_naive!(naive_date_time, "Etc/UTC")

          {:error, _reason} ->
            nil
        end

      # `-00:00` is UTC with the local offset unknown: the instant is exact, so
      # it reads as `Z` would.
      {:error, :invalid_format} ->
        case String.replace_suffix(value, "-00:00", "Z") do
          ^value ->
            nil

          utc_value ->
            parse_date_time(utc_value)
        end

      {:error, _reason} ->
        nil
    end
  end

  ## Private functions — dump

  defp do_dump(%NaiveDateTime{} = naive_date_time, format)
       when is_map_key(@epoch_formats, format) or is_map_key(@date_time_formats, format) do
    naive_date_time
    |> DateTime.from_naive!("Etc/UTC")
    |> do_dump(format)
  end

  defp do_dump(%DateTime{} = date_time, format) when is_map_key(@epoch_formats, format) do
    DateTime.to_unix(date_time, Map.fetch!(@epoch_formats, format))
  end

  defp do_dump(%Date{} = date, "strict_date") do
    Date.to_iso8601(date)
  end

  defp do_dump(%DateTime{} = date_time, "strict_date") do
    date_time |> utc() |> DateTime.to_date() |> Date.to_iso8601()
  end

  defp do_dump(%NaiveDateTime{} = naive_date_time, "strict_date") do
    naive_date_time |> NaiveDateTime.to_date() |> Date.to_iso8601()
  end

  defp do_dump(%NaiveDateTime{} = naive_date_time, format)
       when is_map_key(@naive_formats, format) do
    naive_date_time
    |> precision(Map.fetch!(@naive_formats, format))
    |> NaiveDateTime.to_iso8601()
  end

  defp do_dump(%DateTime{} = date_time, format) when is_map_key(@naive_formats, format) do
    date_time
    |> utc()
    |> DateTime.to_naive()
    |> do_dump(format)
  end

  defp do_dump(%DateTime{} = date_time, format) when is_map_key(@date_time_formats, format) do
    date_time
    |> utc()
    |> precision(Map.fetch!(@date_time_formats, format))
    |> DateTime.to_iso8601()
  end

  defp do_dump(%Time{} = time, format) when is_map_key(@time_formats, format) do
    time
    |> precision(Map.fetch!(@time_formats, format))
    |> Time.to_iso8601()
  end

  # A time-of-day field keeps only the time of a date-time: its wall-clock
  # time for a `NaiveDateTime`, its UTC time for a `DateTime`.
  defp do_dump(%NaiveDateTime{} = naive_date_time, format)
       when is_map_key(@time_formats, format) do
    naive_date_time
    |> NaiveDateTime.to_time()
    |> do_dump(format)
  end

  defp do_dump(%DateTime{} = date_time, format) when is_map_key(@time_formats, format) do
    date_time
    |> utc()
    |> DateTime.to_time()
    |> do_dump(format)
  end

  defp do_dump(value, _format) do
    value
  end

  # Exactly the precision the format declares: `truncate/2` alone keeps a
  # lower precision as it is, and `~U[2019-03-24 01:34:46Z]` would then be
  # written without the `.000` a `_millis` format requires.
  defp precision(%{microsecond: _microsecond} = value, :second) do
    %{value | microsecond: {0, 0}}
  end

  defp precision(%{microsecond: {microsecond, _precision}} = value, :millisecond) do
    %{value | microsecond: {div(microsecond, 1000) * 1000, 3}}
  end

  # Written in UTC whatever zone the `DateTime` is in, so the same instant is
  # always written the same way. Shifting *to* UTC needs nothing beyond the
  # default `Calendar.UTCOnlyTimeZoneDatabase`: the offsets it shifts from are
  # already in the struct.
  defp utc(%DateTime{time_zone: "Etc/UTC"} = date_time), do: date_time
  defp utc(%DateTime{} = date_time), do: DateTime.shift_zone!(date_time, "Etc/UTC")
end
