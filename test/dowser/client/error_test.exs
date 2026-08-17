defmodule Dowser.Client.ErrorTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Error

  # Built via `Error.exception/1` (rather than a `%Error{}` struct literal) so
  # these also exercise `defexception`'s generated `exception/1` — the path
  # `raise Dowser.Client.Error, reason: ...` (used throughout the rest of the
  # codebase) actually goes through.
  describe "message/1" do
    test "an explicit :message wins over any :reason-derived message" do
      error = Error.exception(reason: :conflicting_formats, message: "custom message")
      assert Exception.message(error) == "custom message"
    end

    test "{:unknown_config, name}" do
      error = Error.exception(reason: {:unknown_config, :main})
      assert Exception.message(error) == "unknown config :main"
    end

    test "{:invalid_format, format}" do
      error = Error.exception(reason: {:invalid_format, :xml})
      assert Exception.message(error) == "invalid format :xml, expected :json, :ndjson or :raw"
    end

    test ":conflicting_formats" do
      error = Error.exception(reason: :conflicting_formats)

      assert Exception.message(error) ==
               ":format is mutually exclusive with :req_format and :resp_format"
    end

    test "{:invalid_retry, value}" do
      error = Error.exception(reason: {:invalid_retry, :bogus})

      assert Exception.message(error) ==
               "invalid :retry option :bogus, expected a keyword list or false"
    end

    test "{:invalid_keys, value}" do
      error = Error.exception(reason: {:invalid_keys, :bogus_keys})

      assert Exception.message(error) ==
               "invalid :keys option :bogus_keys, expected :strings, :atoms or :atoms!"
    end

    test "an unrecognized reason falls back to a generic inspect-based message" do
      error = Error.exception(reason: {:something, :unexpected})
      assert Exception.message(error) == "Dowser client error: {:something, :unexpected}"
    end

    test "raise/2 with a module + keyword list builds the exception via exception/1" do
      assert_raise Error, "unknown config :main", fn ->
        raise Error, reason: {:unknown_config, :main}
      end
    end
  end
end
