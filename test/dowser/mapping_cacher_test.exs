defmodule Dowser.MappingCacherTest do
  use ExUnit.Case, async: true

  alias __MODULE__.Cacher

  defmodule Cacher do
    @moduledoc false

    use Dowser.MappingCacher, otp_app: :dowser_mapping_cacher_test
  end

  @repo [endpoint: "http://x:9200"]
  @old %{"properties" => %{"title" => %{"type" => "text"}}}
  @new %{"properties" => %{"title" => %{"type" => "keyword"}}}

  # A fetch that is never released gives up eventually, so that it doesn't
  # outlive the suite.
  @release_timeout :timer.seconds(5)

  setup do
    test = self()
    handler = "#{inspect(__MODULE__)}-#{inspect(test)}"
    event = [:dowser_mapping_cacher_test, :mapping, :stale]

    :ok = :telemetry.attach(handler, event, &__MODULE__.handle_event/4, test)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def handle_event(event, measurements, metadata, test) do
    send(test, {:telemetry, event, measurements, metadata})
  end

  describe "a stale entry" do
    test "is returned at once, and refreshed by a single fetch however many read it" do
      start_cacher(ttl: 0)
      prime(@old)

      results =
        1..50
        |> Task.async_stream(fn _reader -> Cacher.get(@repo, "posts") end, max_concurrency: 50)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.uniq(results) == [{:ok, @old}]
      assert_receive {:fetching, "posts", _pid}
      refute_receive {:fetching, "posts", _pid}, 50
    end

    test "is replaced once its refresh lands" do
      start_cacher(ttl: 0)
      prime(@old)

      assert Cacher.get(@repo, "posts") == {:ok, @old}
      assert_receive {:fetching, "posts", pid}
      release(pid, {:ok, @new})

      assert Cacher.get(@repo, "posts") == {:ok, @new}
    end

    test "is kept when its refresh fails, left alone for a while, and reported" do
      start_cacher(ttl: 0)
      prime(@old)

      assert Cacher.get(@repo, "posts") == {:ok, @old}
      assert_receive {:fetching, "posts", pid}
      release(pid, {:error, :unavailable})

      assert_receive {:telemetry, [:dowser_mapping_cacher_test, :mapping, :stale], %{count: 1},
                      %{index: "posts", reason: :unavailable}}

      # The backoff: the next reads get the stale value without asking again.
      assert Cacher.get(@repo, "posts") == {:ok, @old}
      assert Cacher.lookup(@repo, "posts") == {:ok, @old}
      refute_receive {:fetching, "posts", _pid}, 50
    end

    test "doesn't make a reader wait on a refresh slower than the call timeout" do
      start_cacher(ttl: 0)
      prime(@old)

      assert Cacher.lookup(@repo, "posts") == {:ok, @old}
      assert_receive {:fetching, "posts", pid}

      # The refresh hangs; every read still answers straight away.
      reader =
        Task.async(fn -> Enum.map(1..10, fn _read -> Cacher.lookup(@repo, "posts") end) end)

      assert {:ok, results} = Task.yield(reader, 100)
      assert Enum.uniq(results) == [{:ok, @old}]

      release(pid, {:error, {:exit, {:timeout, {GenServer, :call, []}}}})

      assert Cacher.lookup(@repo, "posts") == {:ok, @old}
    end

    test "survives the sweep" do
      start_cacher(ttl: 0, max_stale: :infinity)
      prime(@old)

      send(Cacher, :sweep)
      _state = :sys.get_state(Cacher)

      assert Cacher.get(@repo, "posts") == {:ok, @old}
    end

    test "is dropped by invalidate/2, and its next reader waits for the fetch" do
      start_cacher(ttl: 0, max_stale: :infinity)
      prime(@old)

      :ok = Cacher.invalidate(@repo, "posts")

      reader = Task.async(fn -> Cacher.get(@repo, "posts") end)
      assert_receive {:fetching, "posts", pid}
      assert Task.yield(reader, 0) == nil

      release(pid, {:error, :unavailable})
      assert Task.await(reader) == {:error, :unavailable}
    end
  end

  describe "an entry past :max_stale" do
    test "is a miss, whose reader waits for the fetch" do
      start_cacher(ttl: 0, max_stale: 1)
      prime(@old)

      # The one wait in this file: there is no other way past a horizon.
      Process.sleep(2)

      reader = Task.async(fn -> Cacher.get(@repo, "posts") end)
      assert_receive {:fetching, "posts", pid}
      assert Task.yield(reader, 0) == nil

      release(pid, {:error, :unavailable})
      assert Task.await(reader) == {:error, :unavailable}
      refute_received {:telemetry, _event, _measurements, _metadata}
    end
  end

  describe "max_stale: 0" do
    test "serves no stale entry: an expired one is a miss its reader waits on" do
      start_cacher(ttl: 0, max_stale: 0)
      prime(@old)

      reader = Task.async(fn -> Cacher.get(@repo, "posts") end)
      assert_receive {:fetching, "posts", pid}
      assert Task.yield(reader, 0) == nil

      release(pid, {:ok, @new})
      assert Task.await(reader) == {:ok, @new}
    end

    test "fails a read whose fetch fails" do
      start_cacher(ttl: 0, max_stale: 0)
      prime(@old)

      reader = Task.async(fn -> Cacher.lookup(@repo, "posts") end)
      assert_receive {:fetching, "posts", pid}

      release(pid, {:error, :unavailable})
      assert Task.await(reader) == {:error, :unavailable}
      refute_received {:telemetry, _event, _measurements, _metadata}
    end
  end

  describe ":refresh_backoff" do
    test "is how long a stale entry whose refresh failed is left alone" do
      start_cacher(ttl: 0, refresh_backoff: 0)
      prime(@old)

      assert Cacher.get(@repo, "posts") == {:ok, @old}
      assert_receive {:fetching, "posts", pid}
      release(pid, {:error, :unavailable})

      # No backoff: the next read refreshes it again.
      assert Cacher.get(@repo, "posts") == {:ok, @old}
      assert_receive {:fetching, "posts", _pid}
    end
  end

  describe ":otp_app" do
    test "given when starting the cacher, names its telemetry events" do
      test = self()
      handler = "#{inspect(__MODULE__)}-otp_app-#{inspect(test)}"
      event = [:my_app, :mapping, :stale]

      :ok = :telemetry.attach(handler, event, &__MODULE__.handle_event/4, test)
      on_exit(fn -> :telemetry.detach(handler) end)

      start_cacher(ttl: 0, otp_app: :my_app)
      prime(@old)

      assert Cacher.get(@repo, "posts") == {:ok, @old}
      assert_receive {:fetching, "posts", pid}
      release(pid, {:error, :unavailable})

      assert_receive {:telemetry, [:my_app, :mapping, :stale], %{count: 1},
                      %{index: "posts", reason: :unavailable}}

      refute_received {:telemetry, [:dowser_mapping_cacher_test | _rest], _measurements,
                       _metadata}
    end
  end

  describe "an entry put by hand" do
    test "is never served stale" do
      start_cacher(max_stale: :infinity)
      :ok = Cacher.put("posts", @old, repo: @repo, ttl: 0)

      reader = Task.async(fn -> Cacher.get(@repo, "posts") end)
      assert_receive {:fetching, "posts", pid}

      release(pid, {:ok, @new})
      assert Task.await(reader) == {:ok, @new}
    end
  end

  ## Helpers

  defp start_cacher(opts) do
    start_supervised!({Cacher, Keyword.put(opts, :fetch, blocking_fetch(self()))})
  end

  # Each fetch tells the test it started, then waits for the test to hand it
  # its result.
  defp blocking_fetch(test) do
    fn _context, index ->
      send(test, {:fetching, index, self()})

      receive do
        {:release, result} -> result
      after
        @release_timeout -> {:error, :never_released}
      end
    end
  end

  # Ends a fetch, and returns once the cacher has handled its result: the
  # fetch sends it before exiting, so a call made after that is handled after.
  defp release(pid, result) do
    ref = Process.monitor(pid)
    send(pid, {:release, result})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    _state = :sys.get_state(Cacher)

    :ok
  end

  # Fetches `mapping` into the cache, through a reader waiting on it.
  defp prime(mapping) do
    reader = Task.async(fn -> Cacher.get(@repo, "posts") end)
    assert_receive {:fetching, "posts", pid}
    release(pid, {:ok, mapping})

    assert Task.await(reader) == {:ok, mapping}
  end
end
