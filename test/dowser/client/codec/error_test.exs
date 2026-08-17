defmodule Dowser.Client.Codec.ErrorTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Codec.Error

  # Built via `Error.exception/1` so these also exercise `defexception`'s
  # generated `exception/1` (the `raise Dowser.Client.Codec.Error, ...` path
  # used throughout the rest of the codebase).
  describe "message/1" do
    test "includes the operation, codec module and the wrapped exception's own message" do
      error =
        Error.exception(
          reason: %RuntimeError{message: "boom"},
          codec: MyCodec,
          operation: :decode
        )

      assert Exception.message(error) == "codec decode failed (MyCodec): boom"
    end

    test "encode operation" do
      error =
        Error.exception(
          reason: %RuntimeError{message: "boom"},
          codec: MyCodec,
          operation: :encode
        )

      assert Exception.message(error) == "codec encode failed (MyCodec): boom"
    end

    test "a nil operation formats as just \"codec\"" do
      error =
        Error.exception(reason: %RuntimeError{message: "boom"}, codec: MyCodec, operation: nil)

      assert Exception.message(error) == "codec failed (MyCodec): boom"
    end

    test "a nil codec omits the parenthesized module" do
      error =
        Error.exception(reason: %RuntimeError{message: "boom"}, codec: nil, operation: :decode)

      assert Exception.message(error) == "codec decode failed: boom"
    end

    test "a non-exception reason is inspected instead of Exception.message/1'd" do
      error = Error.exception(reason: {:bad, :term}, codec: MyCodec, operation: :decode)
      assert Exception.message(error) == "codec decode failed (MyCodec): {:bad, :term}"
    end
  end
end
