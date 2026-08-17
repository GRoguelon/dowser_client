defmodule Dowser.Client.ConfigTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.Config

  describe "new/1" do
    test "builds a config from a keyword list, applying struct defaults" do
      config = Config.new(endpoint: "http://es.internal:9200", auth: {:basic, "u", "p"})

      assert config.endpoint == "http://es.internal:9200"
      assert config.auth == {:basic, "u", "p"}
      assert config.http_adapter == nil
      assert config.json_adapter == nil
      assert config.codec_adapter == nil
      assert config.http_opts == []
      assert config.json_opts == []
      assert config.codec_opts == []
      assert config.keys == :strings
    end

    test "builds a config from a map" do
      config = Config.new(%{endpoint: "http://x:9200", http_adapter: Dowser.Client.HTTP.Req})

      assert config.endpoint == "http://x:9200"
      assert config.http_adapter == Dowser.Client.HTTP.Req
    end

    test "ignores keys that aren't part of the struct" do
      config = Config.new(endpoint: "http://x:9200", not_a_real_field: 1)

      refute Map.has_key?(config, :not_a_real_field)
      assert config.endpoint == "http://x:9200"
    end

    test "raises when :endpoint is missing" do
      assert_raise ArgumentError, ~r/:endpoint/, fn ->
        Config.new(auth: {:basic, "u", "p"})
      end
    end

    # Regression: `new/1` used to build attributes via `if value = Map.get(opts,
    # key)`, which treated an explicit `nil`/`false` the same as "not given" and
    # silently fell back to the struct default. It now uses `Map.take/2`, so an
    # explicitly-given `nil` is preserved instead of being discarded.
    test "preserves an explicitly-given nil instead of falling back to the struct default" do
      config = Config.new(endpoint: "http://x:9200", http_opts: nil, keys: nil)

      assert config.http_opts == nil
      assert config.keys == nil
    end

    test "omitting a key falls back to its struct default" do
      config = Config.new(endpoint: "http://x:9200")

      assert config.http_opts == []
      assert config.keys == :strings
    end
  end

  describe "resolve/1" do
    test "returns a %Config{} as-is" do
      config = Config.new(endpoint: "http://x:9200")
      assert Config.resolve(config) == {:ok, config}
    end

    test "resolves a keyword or map config via new/1" do
      assert {:ok, %Config{endpoint: "http://kw:9200"}} =
               Config.resolve(endpoint: "http://kw:9200")

      assert {:ok, %Config{endpoint: "http://map:9200"}} =
               Config.resolve(%{endpoint: "http://map:9200"})
    end

    test "an unknown named config returns an error" do
      Application.delete_env(:dowser_client, :configs)

      assert {:error, {:unknown_config, :nope}} = Config.resolve(:nope)
    end

    test "a named config is resolved from a keyword-list :configs" do
      put_configs(main: [endpoint: "http://main:9200", http_adapter: Dowser.Client.HTTP.Req])

      assert {:ok, %Config{endpoint: "http://main:9200", http_adapter: Dowser.Client.HTTP.Req}} =
               Config.resolve(:main)
    end

    test "a named config is resolved from a map :configs" do
      Application.put_env(:dowser_client, :configs, %{main: [endpoint: "http://main:9200"]})
      on_exit(fn -> Application.delete_env(:dowser_client, :configs) end)

      assert {:ok, %Config{endpoint: "http://main:9200"}} = Config.resolve(:main)
    end

    test "a named config already stored as a %Config{} is returned as-is" do
      preconfigured = Config.new(endpoint: "http://preconfigured:9200")
      put_configs(main: preconfigured)

      assert Config.resolve(:main) == {:ok, preconfigured}
    end

    test "nil delegates to the :default entry" do
      put_configs(default: [endpoint: "http://configured-default:9200"])

      assert {:ok, %Config{endpoint: "http://configured-default:9200"}} = Config.resolve(nil)
    end

    test "nil returns an :unknown_config error when :default isn't configured — there is no built-in fallback" do
      Application.delete_env(:dowser_client, :configs)

      assert Config.resolve(nil) == {:error, {:unknown_config, :default}}
    end
  end

  describe "Inspect redaction" do
    test "redacts the password of {:basic, user, pass} but keeps the username" do
      config = Config.new(endpoint: "http://x:9200", auth: {:basic, "user", "s3cr3tp4ss"})
      output = inspect(config)

      refute output =~ "s3cr3tp4ss"
      assert output =~ ~s(auth: {:basic, "user", "[FILTERED]"})
      assert output =~ "#Dowser.Client.Config<"
    end

    test "redacts a {:bearer, token}" do
      output = inspect(Config.new(endpoint: "http://x:9200", auth: {:bearer, "tok-abc"}))

      refute output =~ "tok-abc"
      assert output =~ ~s(auth: {:bearer, "[FILTERED]"})
    end

    test "redacts an {:api_key, key}" do
      output = inspect(Config.new(endpoint: "http://x:9200", auth: {:api_key, "key-abc"}))

      refute output =~ "key-abc"
      assert output =~ ~s(auth: {:api_key, "[FILTERED]"})
    end

    test "redacts a {:header, name, value}, keeping the header name" do
      output =
        inspect(Config.new(endpoint: "http://x:9200", auth: {:header, "x-auth", "val-abc"}))

      refute output =~ "val-abc"
      assert output =~ ~s(auth: {:header, "x-auth", "[FILTERED]"})
    end

    test "a config without auth shows auth: nil, not redacted" do
      assert inspect(Config.new(endpoint: "http://x:9200")) =~ "auth: nil"
    end

    test "an auth shape that isn't a tuple is fully redacted (fallback clause)" do
      output = inspect(Config.new(endpoint: "http://x:9200", auth: "raw-secret"))

      refute output =~ "raw-secret"
      assert output =~ ~s(auth: "[FILTERED]")
    end
  end

  defp put_configs(configs) do
    Application.put_env(:dowser_client, :configs, configs)
    on_exit(fn -> Application.delete_env(:dowser_client, :configs) end)
  end
end
