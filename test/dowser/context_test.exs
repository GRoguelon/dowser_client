defmodule Dowser.Client.ContextTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.Context

  describe "new/1" do
    test "builds a context from a keyword list, applying struct defaults" do
      context = Context.new(endpoint: "http://es.internal:9200", auth: {:basic, "u", "p"})

      assert context.endpoint == "http://es.internal:9200"
      assert context.auth == {:basic, "u", "p"}
      assert context.profile == nil
      assert context.profile_opts == []
      assert context.http_opts == []
      assert context.keys == nil
      assert context.decoder == nil
      assert context.encoder == nil
    end

    test "builds a context from a map" do
      context = Context.new(%{endpoint: "http://x:9200", profile: :logs})

      assert context.endpoint == "http://x:9200"
      assert context.profile == :logs
    end

    test "ignores keys that aren't part of the struct" do
      context = Context.new(endpoint: "http://x:9200", not_a_real_field: 1)

      refute Map.has_key?(context, :not_a_real_field)
      assert context.endpoint == "http://x:9200"
    end

    test "raises when :endpoint is missing" do
      assert_raise ArgumentError, ~r/:endpoint/, fn ->
        Context.new(auth: {:basic, "u", "p"})
      end
    end

    # Regression: `new/1` used to build attributes via `if value = Map.get(opts,
    # key)`, which treated an explicit `nil`/`false` the same as "not given" and
    # silently fell back to the struct default. It now uses `Map.take/2`, so an
    # explicitly-given `nil` is preserved instead of being discarded.
    test "preserves an explicitly-given nil instead of falling back to the struct default" do
      context = Context.new(endpoint: "http://x:9200", http_opts: nil, keys: nil)

      assert context.http_opts == nil
      assert context.keys == nil
    end

    test "omitting a key falls back to its struct default" do
      context = Context.new(endpoint: "http://x:9200")

      assert context.http_opts == []
      assert context.keys == nil
    end
  end

  describe "resolve/1" do
    test "returns a %Context{} as-is" do
      context = Context.new(endpoint: "http://x:9200")
      assert Context.resolve(context) == {:ok, context}
    end

    test "resolves a keyword or map context via new/1" do
      assert {:ok, %Context{endpoint: "http://kw:9200"}} =
               Context.resolve(endpoint: "http://kw:9200")

      assert {:ok, %Context{endpoint: "http://map:9200"}} =
               Context.resolve(%{endpoint: "http://map:9200"})
    end

    test "an unknown named context returns an error" do
      Application.delete_env(:dowser_client, :contexts)

      assert {:error, {:unknown_context, :nope}} = Context.resolve(:nope)
    end

    test "a named context is resolved from a keyword-list :contexts" do
      put_contexts(main: [endpoint: "http://main:9200", profile: :main])

      assert {:ok, %Context{endpoint: "http://main:9200", profile: :main}} =
               Context.resolve(:main)
    end

    test "a named context is resolved from a map :contexts" do
      Application.put_env(:dowser_client, :contexts, %{main: [endpoint: "http://main:9200"]})
      on_exit(fn -> Application.delete_env(:dowser_client, :contexts) end)

      assert {:ok, %Context{endpoint: "http://main:9200"}} = Context.resolve(:main)
    end

    test "a named context already stored as a %Context{} is returned as-is" do
      preconfigured = Context.new(endpoint: "http://preconfigured:9200")
      put_contexts(main: preconfigured)

      assert Context.resolve(:main) == {:ok, preconfigured}
    end

    test "nil delegates to the :default entry" do
      put_contexts(default: [endpoint: "http://configured-default:9200"])

      assert {:ok, %Context{endpoint: "http://configured-default:9200"}} = Context.resolve(nil)
    end

    test "nil returns an :unknown_context error when :default isn't configured — there is no built-in fallback" do
      Application.delete_env(:dowser_client, :contexts)

      assert Context.resolve(nil) == {:error, {:unknown_context, :default}}
    end
  end

  describe "Inspect redaction" do
    test "redacts the password of {:basic, user, pass} but keeps the username" do
      context = Context.new(endpoint: "http://x:9200", auth: {:basic, "user", "s3cr3tp4ss"})
      output = inspect(context)

      refute output =~ "s3cr3tp4ss"
      assert output =~ ~s(auth: {:basic, "user", "[FILTERED]"})
      assert output =~ "#Dowser.Client.Context<"
    end

    test "redacts a {:bearer, token}" do
      output = inspect(Context.new(endpoint: "http://x:9200", auth: {:bearer, "tok-abc"}))

      refute output =~ "tok-abc"
      assert output =~ ~s(auth: {:bearer, "[FILTERED]"})
    end

    test "redacts a {:api_key, id, api_key}, keeping the id" do
      output =
        inspect(Context.new(endpoint: "http://x:9200", auth: {:api_key, "id-1", "key-abc"}))

      refute output =~ "key-abc"
      assert output =~ ~s(auth: {:api_key, "id-1", "[FILTERED]"})
    end

    test "redacts an {:api_key, key}" do
      output = inspect(Context.new(endpoint: "http://x:9200", auth: {:api_key, "key-abc"}))

      refute output =~ "key-abc"
      assert output =~ ~s(auth: {:api_key, "[FILTERED]"})
    end

    test "redacts a {:header, name, value}, keeping the header name" do
      output =
        inspect(Context.new(endpoint: "http://x:9200", auth: {:header, "x-auth", "val-abc"}))

      refute output =~ "val-abc"
      assert output =~ ~s(auth: {:header, "x-auth", "[FILTERED]"})
    end

    test "a context without auth shows auth: nil, not redacted" do
      assert inspect(Context.new(endpoint: "http://x:9200")) =~ "auth: nil"
    end

    test "an auth shape that isn't a tuple is fully redacted (fallback clause)" do
      output = inspect(Context.new(endpoint: "http://x:9200", auth: "raw-secret"))

      refute output =~ "raw-secret"
      assert output =~ ~s(auth: "[FILTERED]")
    end
  end

  defp put_contexts(contexts) do
    Application.put_env(:dowser_client, :contexts, contexts)
    on_exit(fn -> Application.delete_env(:dowser_client, :contexts) end)
  end
end
