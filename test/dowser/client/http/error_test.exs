defmodule Dowser.Client.HTTP.ErrorTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.HTTP.Error

  # Built via `Error.exception/1` so these also exercise `defexception`'s
  # generated `exception/1` (the `raise Dowser.Client.HTTP.Error, ...` path
  # used throughout the rest of the codebase).
  describe "message/1" do
    test "includes the uppercased method, url, reason and defaults attempts to 1" do
      error = Error.exception(reason: :timeout, method: :get, url: "http://x")
      assert Exception.message(error) == "HTTP request GET http://x failed: :timeout"
    end

    test "omits the attempt count when attempts is 1" do
      error = Error.exception(reason: :timeout, method: :get, url: "http://x", attempts: 1)
      refute Exception.message(error) =~ "after"
    end

    test "includes the attempt count when attempts > 1" do
      error = Error.exception(reason: :timeout, method: :post, url: "http://x", attempts: 3)

      assert Exception.message(error) ==
               "HTTP request POST http://x failed after 3 attempts: :timeout"
    end

    test "a nil method formats as \"?\"" do
      error = Error.exception(reason: :timeout, method: nil, url: "http://x")
      assert Exception.message(error) == "HTTP request ? http://x failed: :timeout"
    end

    test "a non-atom method is stringified as-is" do
      error = Error.exception(reason: :timeout, method: "GET", url: "http://x")
      assert Exception.message(error) == "HTTP request GET http://x failed: :timeout"
    end

    test "an exception reason uses its own Exception.message/1" do
      error =
        Error.exception(reason: %RuntimeError{message: "boom"}, method: :get, url: "http://x")

      assert Exception.message(error) == "HTTP request GET http://x failed: boom"
    end

    test "a non-exception reason is inspected" do
      error =
        Error.exception(
          reason: {:failed_connect, [{:to_address, {~c"x", 9200}}]},
          method: :get,
          url: "http://x"
        )

      assert Exception.message(error) =~ "failed_connect"
    end
  end
end
