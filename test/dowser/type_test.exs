defmodule Dowser.TypeTest do
  use ExUnit.Case, async: true

  alias Dowser.Type

  doctest Dowser.Type
  doctest Dowser.Type.DateRange
  doctest Dowser.Type.Range

  describe "load/2" do
    test "date_nanos is cast like date" do
      assert Type.load("2026-08-11T00:00:00.000Z", %{
               "type" => "date_nanos",
               "format" => "strict_date_time"
             }) == ~U[2026-08-11 00:00:00.000Z]
    end

    test "a declared format is read leniently, whatever precision the value has" do
      # The backend writes to the declared precision but the index can hold
      # values that predate the mapping, and older clients read these too.
      strict = %{"type" => "date", "format" => "strict_date_time"}

      assert Type.load("2026-09-20T20:46:03Z", strict) == ~U[2026-09-20 20:46:03Z]
      assert Type.load("2026-09-20T20:46:03.899Z", strict) == ~U[2026-09-20 20:46:03.899Z]
      assert Type.load("2026-09-20T15:46:03-05:00", strict) == ~U[2026-09-20 20:46:03Z]

      no_millis = %{"type" => "date", "format" => "strict_date_time_no_millis"}

      assert Type.load("2026-09-20T20:46:03.899Z", no_millis) == ~U[2026-09-20 20:46:03.899Z]

      # A date-only format still only reads a date.
      assert Type.load("2026-09-20T20:46:03Z", %{"type" => "date", "format" => "strict_date"}) ==
               "2026-09-20T20:46:03Z"
    end

    test "no offset, and -00:00, are read as UTC" do
      strict = %{"type" => "date", "format" => "strict_date_time"}

      assert Type.load("2026-09-20T20:46:03.899", strict) == ~U[2026-09-20 20:46:03.899Z]
      assert Type.load("2026-09-20T20:46:03.899-00:00", strict) == ~U[2026-09-20 20:46:03.899Z]
    end

    test "an unparseable date still passes through untouched" do
      field = %{"type" => "date", "format" => "strict_date_time"}

      assert Type.load("not a date", field) == "not a date"
      assert Type.load("2026-13-45T99:99:99Z", field) == "2026-13-45T99:99:99Z"
      assert Type.load("2016-12-31T23:59:60Z", field) == "2016-12-31T23:59:60Z"
    end

    test "only the supported formats are cast; any other, or none, returns the value as stored" do
      for field <- [
            %{"type" => "date"},
            %{"type" => "date", "format" => "strict_date_optional_time"},
            %{"type" => "date", "format" => "yyyy-MM-dd"},
            %{"type" => "date", "format" => "date_hour_minute_second"}
          ] do
        assert Type.load("2026-08-11", field) == "2026-08-11"
        assert Type.load(0, field) == 0
        assert Type.dump(~D[2026-08-11], field) == ~D[2026-08-11]
      end
    end

    test "several formats: read with the first that recognizes the value, written with the first" do
      field = %{"type" => "date", "format" => "strict_date||epoch_millis"}

      assert Type.load("2026-08-11", field) == ~D[2026-08-11]
      assert Type.load(0, field) == ~U[1970-01-01 00:00:00.000Z]
      assert Type.dump(~D[2026-08-11], field) == "2026-08-11"
    end

    test "casts ip strings to :inet tuples" do
      assert Type.load("127.0.0.1", %{"type" => "ip"}) == {127, 0, 0, 1}
    end

    test "casts binary fields from Base64" do
      assert Type.load(Base.encode64("raw"), %{"type" => "binary"}) == "raw"
    end

    test "casts geo_point objects to {lat, lon} tuples" do
      assert Type.load(%{"lat" => 1.2, "lon" => 3.4}, %{"type" => "geo_point"}) ==
               {1.2, 3.4}
    end

    test "casts date_range objects to Date.Range structs" do
      assert Type.load(%{"gte" => "2026-08-01", "lte" => "2026-08-11"}, %{
               "type" => "date_range",
               "format" => "strict_date"
             }) == Date.range(~D[2026-08-01], ~D[2026-08-11])
    end

    test "casts integer_range objects to Range structs" do
      assert Type.load(%{"gte" => 1, "lte" => 10}, %{"type" => "integer_range"}) == 1..10
    end

    test "an integer_range with non-integer bounds passes through unchanged" do
      assert Type.load(%{"gte" => 1.5, "lte" => 2.5}, %{"type" => "integer_range"}) ==
               %{"gte" => 1.5, "lte" => 2.5}
    end

    test "an unmatched type falls back to identity" do
      assert Type.load("hello", %{"type" => "text"}) == "hello"
    end

    test "nil short-circuits" do
      assert Type.load(nil, %{"type" => "date"}) == nil
    end
  end

  describe "dump/2" do
    test "dumps DateTime to ISO-8601, at exactly the precision the format declares" do
      field = &%{"type" => "date", "format" => &1}

      assert Type.dump(~U[2026-09-20 20:46:03.899123Z], field.("strict_date_time")) ==
               "2026-09-20T20:46:03.899Z"

      assert Type.dump(~U[2026-09-20 20:46:03.899123Z], field.("strict_date_time_no_millis")) ==
               "2026-09-20T20:46:03Z"

      # Padded to three digits rather than left without a fraction.
      assert Type.dump(~U[2026-08-11 00:00:00Z], field.("strict_date_time")) ==
               "2026-08-11T00:00:00.000Z"
    end

    test "NaiveDateTime and Time are truncated or padded the same way" do
      field = &%{"type" => "date", "format" => &1}

      assert Type.dump(~N[2026-09-20 20:46:03.899123], field.("strict_date_hour_minute_second")) ==
               "2026-09-20T20:46:03"

      assert Type.dump(~N[2026-09-20 20:46:03], field.("strict_date_hour_minute_second_millis")) ==
               "2026-09-20T20:46:03.000"

      assert Type.dump(~T[20:46:03.899123], field.("strict_hour_minute_second")) == "20:46:03"
      assert Type.dump(~T[20:46:03], field.("strict_hour_minute_second_millis")) == "20:46:03.000"
    end

    test "epoch formats truncate to their unit" do
      field = &%{"type" => "date", "format" => &1}

      assert Type.dump(~U[2019-03-24 01:34:46.123456Z], field.("epoch_millis")) ==
               1_553_391_286_123

      assert Type.dump(~U[2019-03-24 01:34:46.123456Z], field.("epoch_second")) == 1_553_391_286
      assert Type.dump(~N[2019-03-24 01:34:46.123], field.("epoch_second")) == 1_553_391_286
    end

    test "a date-time written to strict_date keeps its date" do
      field = %{"type" => "date", "format" => "strict_date"}

      assert Type.dump(~U[2019-03-24 01:34:46Z], field) == "2019-03-24"
      assert Type.dump(~N[2019-03-24 01:34:46], field) == "2019-03-24"
    end

    test "dumps :inet tuples to strings" do
      assert Type.dump({127, 0, 0, 1}, %{"type" => "ip"}) == "127.0.0.1"
    end

    test "dumps raw binaries to Base64" do
      assert Type.dump("raw", %{"type" => "binary"}) == Base.encode64("raw")
    end

    test "dumps {lat, lon} tuples to geo_point objects" do
      assert Type.dump({1.2, 3.4}, %{"type" => "geo_point"}) ==
               %{"lat" => 1.2, "lon" => 3.4}
    end

    test "dumps Date.Range structs to date_range objects" do
      assert Type.dump(Date.range(~D[2026-08-01], ~D[2026-08-11]), %{
               "type" => "date_range",
               "format" => "strict_date"
             }) == %{"gte" => "2026-08-01", "lte" => "2026-08-11"}
    end

    test "dumps Range structs to integer_range objects" do
      assert Type.dump(1..10, %{"type" => "integer_range"}) == %{"gte" => 1, "lte" => 10}
    end

    test "a non-Range value for integer_range passes through unchanged" do
      assert Type.dump("not a range", %{"type" => "integer_range"}) == "not a range"
    end

    test "an unmatched type falls back to identity" do
      assert Type.dump("hello", %{"type" => "text"}) == "hello"
    end

    test "nil short-circuits" do
      assert Type.dump(nil, %{"type" => "date"}) == nil
    end
  end

  describe "a type module of your own" do
    defmodule CustomType do
      @behaviour Dowser.Type

      @impl true
      def load(value, %{"type" => "scaled_float", "scaling_factor" => factor})
          when is_integer(value) do
        value / factor
      end

      # `date` is already handled by the built-in type; matching it first
      # replaces that cast.
      def load(value, %{"type" => "date"}), do: {:raw, value}

      def load(value, field), do: Dowser.Type.load(value, field)

      @impl true
      def dump(value, %{"type" => "scaled_float", "scaling_factor" => factor})
          when is_float(value) do
        round(value * factor)
      end

      def dump(value, field), do: Dowser.Type.dump(value, field)
    end

    test "a delegated type still uses the built-in type" do
      assert CustomType.load("127.0.0.1", %{"type" => "ip"}) == {127, 0, 0, 1}
    end

    test "an added type is cast by the new clause" do
      field = %{"type" => "scaled_float", "scaling_factor" => 100}

      assert CustomType.load(1234, field) == 12.34
      assert CustomType.dump(12.34, field) == 1234
    end

    test "a clause over a built-in type replaces that cast" do
      assert CustomType.load("2026-08-11", %{"type" => "date"}) == {:raw, "2026-08-11"}
    end

    test "delegating inherits the nil short-circuit and the identity fallback" do
      assert CustomType.load(nil, %{"type" => "ip"}) == nil
      assert CustomType.load("hello", %{"type" => "text"}) == "hello"
    end
  end

  describe "naive date-time formats" do
    @naive %{"type" => "date", "format" => "strict_date_hour_minute_second"}
    @naive_millis %{"type" => "date", "format" => "strict_date_hour_minute_second_millis"}

    test "load to a NaiveDateTime, discarding an offset rather than failing on one" do
      assert Type.load("2026-09-20T20:46:03", @naive) == ~N[2026-09-20 20:46:03]
      assert Type.load("2026-09-20T20:46:03.899", @naive_millis) == ~N[2026-09-20 20:46:03.899]
      assert Type.load("2026-09-20T20:46:03Z", @naive) == ~N[2026-09-20 20:46:03]
    end

    test "dump to the declared precision, with no offset" do
      naive_date_time = ~N[2026-09-20 20:46:03.899123]

      assert Type.dump(naive_date_time, @naive) == "2026-09-20T20:46:03"
      assert Type.dump(naive_date_time, @naive_millis) == "2026-09-20T20:46:03.899"
    end

    test "a DateTime is written as its UTC wall-clock time" do
      date_time = DateTime.new!(~D[2026-09-20], ~T[22:46:03], "Etc/UTC")

      assert Type.dump(date_time, @naive) == "2026-09-20T22:46:03"
    end

    test "an unparseable value passes through untouched" do
      assert Type.load("not a date", @naive) == "not a date"
    end
  end

  describe "the single-format date fields" do
    # format, stored value, Elixir term — each format read by the Elixir
    # function that parses it, and written back to the same value.
    @formats [
      {"epoch_millis", 1_553_391_286_000, ~U[2019-03-24 01:34:46.000Z]},
      {"epoch_second", 1_553_391_286, ~U[2019-03-24 01:34:46Z]},
      {"strict_date", "2019-03-23", ~D[2019-03-23]},
      {"strict_date_hour_minute_second", "2019-03-23T21:34:46", ~N[2019-03-23 21:34:46]},
      {"strict_date_hour_minute_second_millis", "2019-03-23T21:34:46.123",
       ~N[2019-03-23 21:34:46.123]},
      {"strict_date_time_no_millis", "2019-03-23T21:34:46-04:00", ~U[2019-03-24 01:34:46Z]},
      {"strict_date_time", "2019-03-23T21:34:46.123-04:00", ~U[2019-03-24 01:34:46.123Z]},
      {"strict_hour_minute_second", "21:34:46", ~T[21:34:46]},
      {"strict_hour_minute_second_millis", "21:34:46.123", ~T[21:34:46.123]}
    ]

    test "each loads to its Elixir term" do
      for {format, stored, term} <- @formats do
        assert Type.load(stored, %{"type" => "date", "format" => format}) == term,
               "#{format} loaded #{inspect(stored)} wrong"
      end
    end

    test "each dumps back, an offset written as UTC" do
      for {format, _stored, term} <- @formats do
        field = %{"type" => "date", "format" => format}

        assert Type.load(Type.dump(term, field), field) == term,
               "#{format} did not round-trip #{inspect(term)}"
      end

      assert Type.dump(~U[2019-03-24 01:34:46Z], %{
               "type" => "date",
               "format" => "strict_date_time_no_millis"
             }) == "2019-03-24T01:34:46Z"
    end

    test "a time-of-day field keeps only the time of a date-time" do
      field = %{"type" => "date", "format" => "strict_hour_minute_second"}

      assert Type.dump(~N[2019-03-23 21:34:46.123], field) == "21:34:46"
      assert Type.dump(~U[2019-03-24 01:34:46Z], field) == "01:34:46"
    end
  end

  describe "time zones" do
    # 21:34:46.123 in New York (EDT, UTC-4), built by hand: this suite runs on
    # the default UTC-only time-zone database, as an application without
    # `tzdata` does, and shifting *to* UTC must work there too.
    @new_york %DateTime{
      year: 2019,
      month: 3,
      day: 23,
      hour: 21,
      minute: 34,
      second: 46,
      microsecond: {123_000, 3},
      time_zone: "America/New_York",
      zone_abbr: "EDT",
      utc_offset: -18_000,
      std_offset: 3_600
    }

    test "an offset in the value is applied, and a single UTC DateTime loaded" do
      field = %{"type" => "date", "format" => "strict_date_time"}

      assert Type.load("2019-03-23T21:34:46.123-04:00", field) == ~U[2019-03-24 01:34:46.123Z]
    end

    test "a DateTime in another zone is dumped as its UTC instant" do
      dump = fn format -> Type.dump(@new_york, %{"type" => "date", "format" => format}) end

      assert dump.("strict_date_time") == "2019-03-24T01:34:46.123Z"
      assert dump.("strict_date_time_no_millis") == "2019-03-24T01:34:46Z"
      assert dump.("strict_date_hour_minute_second") == "2019-03-24T01:34:46"
      assert dump.("strict_hour_minute_second") == "01:34:46"
      assert dump.("epoch_second") == 1_553_391_286
    end
  end

  describe "date_range" do
    @strict_date %{"type" => "date_range", "format" => "strict_date"}

    test "only a strict_date field is cast" do
      value = %{"gte" => "2026-08-01", "lte" => "2026-08-11"}

      assert Type.load(value, @strict_date) == Date.range(~D[2026-08-01], ~D[2026-08-11])
      assert Type.load(value, %{"type" => "date_range"}) == value

      assert Type.load(value, %{"type" => "date_range", "format" => "strict_date_time"}) ==
               value
    end

    test "anything a Date.Range can't hold is returned as stored" do
      for value <- [
            %{"gt" => "2026-08-01", "lt" => "2026-08-11"},
            %{"gte" => "2026-08-01"},
            %{"gte" => "2026-08-01T00:00:00Z", "lte" => "2026-08-11T00:00:00Z"},
            %{"gte" => "2026-08-11", "lte" => "2026-08-01"}
          ] do
        assert Type.load(value, @strict_date) == value
      end
    end

    test "only a strict_date field, and a range stepping by one day, is dumped" do
      range = Date.range(~D[2026-08-01], ~D[2026-08-11])

      assert Type.dump(range, @strict_date) == %{"gte" => "2026-08-01", "lte" => "2026-08-11"}
      assert Type.dump(range, %{"type" => "date_range"}) == range

      assert %Date.Range{} =
               Type.dump(Date.range(~D[2026-08-01], ~D[2026-08-11], 2), @strict_date)
    end
  end

  describe "integer_range and long_range" do
    test "both cast an inclusive integer range to a Range" do
      for type <- ["integer_range", "long_range"] do
        field = %{"type" => type}

        assert Type.load(%{"gte" => 1, "lte" => 10}, field) == 1..10
        assert Type.dump(1..10, field) == %{"gte" => 1, "lte" => 10}
      end
    end

    test "anything a Range can't hold is returned as stored" do
      field = %{"type" => "long_range"}

      for value <- [
            %{"gte" => 1},
            %{"gt" => 1, "lt" => 10},
            %{"gte" => 1.5, "lte" => 2.5},
            %{"gte" => 10, "lte" => 1}
          ] do
        assert Type.load(value, field) == value
      end

      assert Type.dump(1..10//2, field) == 1..10//2
      assert Type.dump(10..1//-1, field) == 10..1//-1
    end
  end

  describe "epoch formats" do
    test "epoch_second loads and dumps whole seconds" do
      field = %{"type" => "date", "format" => "epoch_second"}

      assert Type.load(1_789_000_000, field) == DateTime.from_unix!(1_789_000_000)
      assert Type.dump(DateTime.from_unix!(1_789_000_000), field) == 1_789_000_000
    end
  end

  describe "a mapping entry with no type" do
    test "falls back to identity in both directions" do
      assert Type.load("hello", nil) == "hello"
      assert Type.dump("hello", %{"properties" => %{}}) == "hello"
    end
  end
end
