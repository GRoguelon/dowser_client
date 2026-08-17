defmodule Dowser.Client.Retry do
  @moduledoc """
  Generic retry policy for transient HTTP failures.

  Lives outside `Dowser.Client.HTTP.*` deliberately: retry is orchestration
  around whichever adapter is configured, not a transport concern, so it
  works uniformly for `:httpc`, `Req`, `:hackney` and any custom adapter.

  `resolve/1` turns `opts[:retry]` into a full config (stored on
  `%Dowser.Client.Request{}`); `run/2` drives an arbitrary zero-arity `fun`
  through that policy, sleeping between attempts with exponential
  full-jitter backoff; `transient?/1` classifies an adapter's raw
  `{:error, reason}` payload.

  ## Options

  `opts[:retry]` accepts:

    * `false` — disables retries (`max_attempts: 1`).
    * a keyword list — merged over the defaults, so a partial override (e.g.
      `retry: [max_attempts: 5]`) only changes the given keys:
        * `:max_attempts` — total attempts, including the first (default `3`).
        * `:base_delay_ms` / `:max_delay_ms` — exponential full-jitter backoff
          bounds (default `200` / `2_000`).
        * `:retryable_statuses` — response statuses treated as transient
          (default `[429, 502, 503, 504]`).
  """

  alias Dowser.Client.Error
  alias Dowser.Client.Response

  ## Typespecs

  @type config :: keyword()

  ## Module attributes

  @default [
    max_attempts: 3,
    base_delay_ms: 200,
    max_delay_ms: 2_000,
    retryable_statuses: [429, 502, 503, 504]
  ]

  @transient_reasons [:timeout, :econnrefused, :closed, :enetunreach, :ehostunreach, :nxdomain]

  ## Public functions

  @doc """
  Resolves `opts[:retry]` into a full retry config.

  Returns `{:ok, config}` or `{:error, %Dowser.Client.Error{}}` when
  `opts[:retry]` is neither `false` nor a keyword list.
  """
  @spec resolve(keyword()) :: {:ok, config()} | {:error, Error.t()}
  def resolve(opts) do
    case Keyword.get(opts, :retry, []) do
      false -> {:ok, Keyword.put(@default, :max_attempts, 1)}
      nil -> {:ok, @default}
      custom when is_list(custom) -> {:ok, Keyword.merge(@default, custom)}
      other -> {:error, %Error{reason: {:invalid_retry, other}}}
    end
  end

  @doc """
  Runs `fun` up to `config[:max_attempts]` times, retrying as long as the
  result is transient (a retryable HTTP status or a transient transport
  error) and attempts remain, sleeping with jittered backoff in between.

  Returns `{result, attempts}` — `fun`'s final return value and the number
  of times it was actually called.
  """
  @spec run(config(), (-> term())) :: {term(), pos_integer()}
  def run(config, fun), do: attempt(config, fun, 1)

  @doc "Whether an adapter's raw `{:error, reason}` payload looks transient."
  @spec transient?(term()) :: boolean()
  def transient?(%{reason: reason}), do: transient?(reason)
  def transient?({:failed_connect, _}), do: true
  def transient?(reason) when reason in @transient_reasons, do: true
  def transient?(_reason), do: false

  @doc false
  # Exposed (not private) so backoff bounds are unit-testable without
  # actually sleeping.
  @spec delay(config(), pos_integer()) :: pos_integer()
  def delay(config, attempt_number) do
    base = Keyword.fetch!(config, :base_delay_ms)
    max = Keyword.fetch!(config, :max_delay_ms)
    ceiling = min(max, base * Integer.pow(2, attempt_number - 1))
    :rand.uniform(max(ceiling, 1))
  end

  ## Private functions

  defp attempt(config, fun, attempt_number) do
    result = fun.()
    max_attempts = Keyword.fetch!(config, :max_attempts)

    if attempt_number < max_attempts and retry?(result, config) do
      Process.sleep(delay(config, attempt_number))
      attempt(config, fun, attempt_number + 1)
    else
      {result, attempt_number}
    end
  end

  defp retry?({:ok, %Response{status: status}}, config),
    do: status in Keyword.fetch!(config, :retryable_statuses)

  defp retry?({:error, reason}, _config), do: transient?(reason)
end
