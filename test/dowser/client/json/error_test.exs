defmodule Dowser.Client.JSON.ErrorTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.JSON.Error

  # Built via `Error.exception/1` so these also exercise `defexception`'s
  # generated `exception/1` (the `raise Dowser.Client.JSON.Error, ...` path
  # used throughout the rest of the codebase).
  describe "message/1" do
    test "encode operation with an exception reason" do
      error = Error.exception(reason: %RuntimeError{message: "boom"}, operation: :encode)
      assert Exception.message(error) == "JSON encode failed: boom"
    end

    test "decode operation with a non-exception reason is inspected" do
      error = Error.exception(reason: {:unexpected, :token}, operation: :decode)
      assert Exception.message(error) == "JSON decode failed: {:unexpected, :token}"
    end

    test "a nil operation formats as just \"codec\"" do
      error = Error.exception(reason: :whatever, operation: nil)
      assert Exception.message(error) == "JSON codec failed: :whatever"
    end
  end
end
