defmodule Dowser.Client.RetryTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Error
  alias Dowser.Client.Response
  alias Dowser.Client.Retry

  @fast [base_delay_ms: 1, max_delay_ms: 1]

  describe "resolve/1" do
    test "defaults when :retry is absent" do
      assert {:ok, context} = Retry.resolve([])
      assert context[:max_attempts] == 3
      assert context[:base_delay_ms] == 200
      assert context[:max_delay_ms] == 2_000
      assert context[:retryable_statuses] == [429, 503]
      assert context[:ambiguous_statuses] == [502, 504]
      assert context[:idempotent] == false
      assert context[:respect_retry_after] == true
    end

    test "derives :idempotent from the method" do
      assert {:ok, context} = Retry.resolve([], :get)
      assert context[:idempotent] == true

      assert {:ok, context} = Retry.resolve([], :put)
      assert context[:idempotent] == true

      assert {:ok, context} = Retry.resolve([], :post)
      assert context[:idempotent] == false
    end

    test "an explicit :idempotent wins over the method" do
      assert {:ok, context} = Retry.resolve([retry: [idempotent: true]], :post)
      assert context[:idempotent] == true
    end

    test "a partial keyword list overrides only the given keys" do
      assert {:ok, context} = Retry.resolve(retry: [max_attempts: 5])
      assert context[:max_attempts] == 5
      assert context[:base_delay_ms] == 200
    end

    test "an explicit nil is treated the same as absent (defaults, not disabled)" do
      assert Retry.resolve(retry: nil) == Retry.resolve([])
    end

    test "false disables retries" do
      assert {:ok, context} = Retry.resolve(retry: false)
      assert context[:max_attempts] == 1
    end

    test "an invalid value is a generic error" do
      assert {:error, %Error{reason: {:invalid_retry, :bogus}}} = Retry.resolve(retry: :bogus)
    end
  end

  describe "run/2" do
    test "succeeds on the first attempt without sleeping" do
      assert {{:ok, %Response{status: 200}}, 1} =
               Retry.run(context(), fn -> {:ok, %Response{status: 200}} end)
    end

    test "retries a timeout until it succeeds, for an idempotent request" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n < 2, do: {:error, :timeout}, else: {:ok, %Response{status: 200}}
      end

      assert {{:ok, %Response{status: 200}}, 3} =
               Retry.run(context(max_attempts: 5, idempotent: true), fun)
    end

    test "gives up after max_attempts and returns the last error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      fun = fn -> Agent.get_and_update(counter, &{{:error, :timeout}, &1 + 1}) end

      assert {{:error, :timeout}, 3} = Retry.run(context(max_attempts: 3, idempotent: true), fun)
      assert Agent.get(counter, & &1) == 3
    end

    test "does not retry an ambiguous failure of a non-idempotent request" do
      for reason <- [:timeout, :etimedout, :econnreset, :closed, :socket_closed_remotely] do
        {:ok, counter} = Agent.start_link(fn -> 0 end)
        fun = fn -> Agent.get_and_update(counter, &{{:error, reason}, &1 + 1}) end

        # The server may have applied it: sending it again would write twice.
        assert {{:error, ^reason}, 1} = Retry.run(context(max_attempts: 5), fun)
        assert Agent.get(counter, & &1) == 1
      end
    end

    test "retries an unreachable server whether or not the request is idempotent" do
      for reason <- [:econnrefused, :nxdomain, :enetunreach, {:failed_connect, []}] do
        {:ok, counter} = Agent.start_link(fn -> 0 end)
        fun = fn -> Agent.get_and_update(counter, &{{:error, reason}, &1 + 1}) end

        assert {{:error, ^reason}, 3} = Retry.run(context(max_attempts: 3), fun)
      end
    end

    test "retries a rejection whether or not the request is idempotent" do
      for status <- [429, 503] do
        {:ok, counter} = Agent.start_link(fn -> 0 end)
        fun = fn -> Agent.get_and_update(counter, &{{:ok, %Response{status: status}}, &1 + 1}) end

        assert {{:ok, %Response{}}, 3} = Retry.run(context(max_attempts: 3), fun)
      end
    end

    test "retries an ambiguous status only for an idempotent request" do
      for status <- [502, 504] do
        fun = fn -> {:ok, %Response{status: status}} end

        assert {{:ok, %Response{}}, 1} = Retry.run(context(max_attempts: 3), fun)

        assert {{:ok, %Response{}}, 3} =
                 Retry.run(context(max_attempts: 3, idempotent: true), fun)
      end
    end

    test "stops once the elapsed-time budget is spent" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn ->
        Process.sleep(20)
        Agent.get_and_update(counter, &{{:ok, %Response{status: 429}}, &1 + 1})
      end

      assert {{:ok, %Response{status: 429}}, attempts} =
               Retry.run(context(max_attempts: 50, max_elapsed_ms: 60), fun)

      assert attempts < 50
    end

    test "waits what Retry-After asks for" do
      response = %Response{status: 429, headers: %{"retry-after" => "1"}}
      fun = fn -> {:ok, response} end

      # One second is more than the budget allows, so the wait never happens.
      assert {{:ok, %Response{status: 429}}, 1} =
               Retry.run(context(max_attempts: 3, max_elapsed_ms: 100), fun)

      # And more than the cap the policy accepts at all.
      assert {{:ok, %Response{status: 429}}, 1} =
               Retry.run(context(max_attempts: 3, max_retry_after_ms: 500), fun)
    end

    test "ignores Retry-After when told to" do
      response = %Response{status: 429, headers: %{"retry-after" => "3600"}}
      fun = fn -> {:ok, response} end

      assert {{:ok, %Response{status: 429}}, 3} =
               Retry.run(context(max_attempts: 3, respect_retry_after: false), fun)
    end

    test "retries a retryable status" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n < 1, do: {:ok, %Response{status: 503}}, else: {:ok, %Response{status: 200}}
      end

      assert {{:ok, %Response{status: 200}}, 2} = Retry.run(context(max_attempts: 5), fun)
    end

    test "does not retry a non-retryable status" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      fun = fn -> Agent.get_and_update(counter, &{{:ok, %Response{status: 404}}, &1 + 1}) end

      assert {{:ok, %Response{status: 404}}, 1} = Retry.run(context(max_attempts: 5), fun)
      assert Agent.get(counter, & &1) == 1
    end

    test "does not retry a non-transient error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      fun = fn -> Agent.get_and_update(counter, &{{:error, :enoent}, &1 + 1}) end

      assert {{:error, :enoent}, 1} = Retry.run(context(max_attempts: 5), fun)
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

  describe "delay/3 — Retry-After" do
    test "reads a delay in seconds" do
      response = {:ok, %Response{status: 429, headers: %{"retry-after" => "2"}}}

      assert Retry.delay(context(), 1, response) == 2_000
    end

    test "reads an HTTP date" do
      # `rfc1123_date/1` takes a *local* time and renders it as GMT.
      later =
        :calendar.local_time()
        |> :calendar.datetime_to_gregorian_seconds()
        |> Kernel.+(5)
        |> :calendar.gregorian_seconds_to_datetime()
        |> :httpd_util.rfc1123_date()
        |> to_string()

      response = {:ok, %Response{status: 503, headers: %{"retry-after" => later}}}

      assert Retry.delay(context(), 1, response) in 4_000..5_000
    end

    test "a date in the past is no wait at all, not a negative one" do
      past = "Wed, 21 Oct 2015 07:28:00 GMT"
      response = {:ok, %Response{status: 503, headers: %{"retry-after" => past}}}

      assert Retry.delay(context(), 1, response) == 1
    end

    test "an unparseable value falls back to the backoff" do
      response = {:ok, %Response{status: 503, headers: %{"retry-after" => "soon"}}}

      assert Retry.delay(context(), 1, response) <= 1
    end

    test "stops rather than waiting longer than the cap" do
      response = {:ok, %Response{status: 429, headers: %{"retry-after" => "120"}}}

      assert Retry.delay(context(max_retry_after_ms: 60_000), 1, response) == :stop
    end
  end

  describe "ambiguous?/1" do
    test "a broken connection is ambiguous, a refused one is not" do
      assert Retry.ambiguous?(:timeout)
      assert Retry.ambiguous?(:econnreset)
      assert Retry.ambiguous?(%{reason: :closed})
      refute Retry.ambiguous?(:econnrefused)
      refute Retry.ambiguous?(:nxdomain)
      refute Retry.ambiguous?({:failed_connect, []})
      refute Retry.ambiguous?(:enoent)
    end
  end

  describe "delay/2" do
    test "stays within the exponential full-jitter bounds" do
      context = context(base_delay_ms: 100, max_delay_ms: 1_000)

      for attempt <- 1..6 do
        ceiling = min(1_000, 100 * Integer.pow(2, attempt - 1))

        for _ <- 1..200 do
          delay = Retry.delay(context, attempt)
          assert delay >= 1
          assert delay <= ceiling
        end
      end
    end

    test "never raises even with a zero base_delay_ms" do
      context = context(base_delay_ms: 0, max_delay_ms: 0)
      assert Retry.delay(context, 1) >= 1
    end
  end

  defp context(overrides \\ []) do
    {:ok, context} = Retry.resolve(retry: Keyword.merge(@fast, overrides))
    context
  end
end
