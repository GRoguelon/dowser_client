defmodule Dowser.Client.RetryTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Error
  alias Dowser.Client.Response
  alias Dowser.Client.Retry

  @fast [base_delay_ms: 1, max_delay_ms: 1]

  describe "resolve/1" do
    test "defaults when :retry is absent" do
      assert {:ok, config} = Retry.resolve([])
      assert config[:max_attempts] == 3
      assert config[:base_delay_ms] == 200
      assert config[:max_delay_ms] == 2_000
      assert config[:retryable_statuses] == [429, 502, 503, 504]
    end

    test "a partial keyword list overrides only the given keys" do
      assert {:ok, config} = Retry.resolve(retry: [max_attempts: 5])
      assert config[:max_attempts] == 5
      assert config[:base_delay_ms] == 200
    end

    test "an explicit nil is treated the same as absent (defaults, not disabled)" do
      assert Retry.resolve(retry: nil) == Retry.resolve([])
    end

    test "false disables retries" do
      assert {:ok, config} = Retry.resolve(retry: false)
      assert config[:max_attempts] == 1
    end

    test "an invalid value is a generic error" do
      assert {:error, %Error{reason: {:invalid_retry, :bogus}}} = Retry.resolve(retry: :bogus)
    end
  end

  describe "run/2" do
    test "succeeds on the first attempt without sleeping" do
      assert {{:ok, %Response{status: 200}}, 1} =
               Retry.run(config(), fn -> {:ok, %Response{status: 200}} end)
    end

    test "retries a transient error until it succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n < 2, do: {:error, :timeout}, else: {:ok, %Response{status: 200}}
      end

      assert {{:ok, %Response{status: 200}}, 3} = Retry.run(config(max_attempts: 5), fun)
    end

    test "gives up after max_attempts and returns the last error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      fun = fn -> Agent.get_and_update(counter, &{{:error, :timeout}, &1 + 1}) end

      assert {{:error, :timeout}, 3} = Retry.run(config(max_attempts: 3), fun)
      assert Agent.get(counter, & &1) == 3
    end

    test "retries a retryable status" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n < 1, do: {:ok, %Response{status: 503}}, else: {:ok, %Response{status: 200}}
      end

      assert {{:ok, %Response{status: 200}}, 2} = Retry.run(config(max_attempts: 5), fun)
    end

    test "does not retry a non-retryable status" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      fun = fn -> Agent.get_and_update(counter, &{{:ok, %Response{status: 404}}, &1 + 1}) end

      assert {{:ok, %Response{status: 404}}, 1} = Retry.run(config(max_attempts: 5), fun)
      assert Agent.get(counter, & &1) == 1
    end

    test "does not retry a non-transient error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      fun = fn -> Agent.get_and_update(counter, &{{:error, :enoent}, &1 + 1}) end

      assert {{:error, :enoent}, 1} = Retry.run(config(max_attempts: 5), fun)
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "transient?/1" do
    test "recognizes bare transient reason atoms" do
      assert Retry.transient?(:timeout)
      assert Retry.transient?(:econnrefused)
      assert Retry.transient?(:closed)
      assert Retry.transient?(:enetunreach)
      assert Retry.transient?(:ehostunreach)
      assert Retry.transient?(:nxdomain)
    end

    test "recognizes httpc's :failed_connect tuple" do
      assert Retry.transient?({:failed_connect, [{:to_address, {~c"x", 9200}}]})
    end

    test "unwraps a Mint-style %{reason: reason} struct" do
      assert Retry.transient?(%{reason: :timeout})
      refute Retry.transient?(%{reason: :enoent})
    end

    test "refutes a non-transient reason" do
      refute Retry.transient?(:enoent)
      refute Retry.transient?(%ArgumentError{})
    end
  end

  describe "delay/2" do
    test "stays within the exponential full-jitter bounds" do
      config = config(base_delay_ms: 100, max_delay_ms: 1_000)

      for attempt <- 1..6 do
        ceiling = min(1_000, 100 * Integer.pow(2, attempt - 1))

        for _ <- 1..200 do
          delay = Retry.delay(config, attempt)
          assert delay >= 1
          assert delay <= ceiling
        end
      end
    end

    test "never raises even with a zero base_delay_ms" do
      config = config(base_delay_ms: 0, max_delay_ms: 0)
      assert Retry.delay(config, 1) >= 1
    end
  end

  defp config(overrides \\ []) do
    {:ok, config} = Retry.resolve(retry: Keyword.merge(@fast, overrides))
    config
  end
end
