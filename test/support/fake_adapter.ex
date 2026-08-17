defmodule Dowser.Client.HTTP.FakeAdapter do
  @moduledoc """
  Test-only `Dowser.Client.HTTP.Adapter`.

  `set/1` scripts the sequence of `request/5` return values (the last is
  repeated once exhausted); `calls/0` reports how many times it's been
  invoked. Uses a fixed process name, so start it via `start_supervised!/1`
  in `async: false` tests only.
  """

  @behaviour Dowser.Client.HTTP.Adapter

  use Agent

  ## Public functions

  def start_link(_opts \\ []), do: Agent.start_link(fn -> {[], 0} end, name: __MODULE__)

  def set(results) when is_list(results),
    do: Agent.update(__MODULE__, fn {_, c} -> {results, c} end)

  def calls, do: Agent.get(__MODULE__, fn {_, c} -> c end)

  @impl Dowser.Client.HTTP.Adapter
  def request(_method, _url, _headers, _body, _opts) do
    Agent.get_and_update(__MODULE__, fn
      {[last], c} -> {last, {[last], c + 1}}
      {[next | rest], c} -> {next, {rest, c + 1}}
      {[], c} -> {{:error, :no_script}, {[], c + 1}}
    end)
  end
end
