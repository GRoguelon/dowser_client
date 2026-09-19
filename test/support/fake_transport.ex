defmodule Dowser.Client.HTTP.FakeTransport do
  @moduledoc """
  Scripts `Dowser.Client.HTTP.Stub` with a sequence of transport results, for
  testing the retry pipeline without a server.

  `script/1` registers the stub for the calling process and returns a handle;
  each request pops the next result (the last one repeats once exhausted), and
  `calls/1` reports how many requests were made. State lives in a linked
  `Agent`, so tests stay `async: true`.
  """

  alias Dowser.Client.HTTP.Stub

  ## Public functions

  def script(results) when is_list(results) do
    {:ok, agent} = Agent.start_link(fn -> {results, 0} end)

    Stub.stub(fn _method, _url, _headers, _body, _opts -> next(agent) end)

    agent
  end

  def calls(agent), do: Agent.get(agent, fn {_results, calls} -> calls end)

  ## Private functions

  defp next(agent) do
    Agent.get_and_update(agent, fn
      {[last], calls} -> {last, {[last], calls + 1}}
      {[result | rest], calls} -> {result, {rest, calls + 1}}
      {[], calls} -> {{:error, :no_script}, {[], calls + 1}}
    end)
  end
end
