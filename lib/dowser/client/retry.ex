defmodule Dowser.Client.Retry do
  @moduledoc """
  Retry policy for transient HTTP failures.

  Lives outside `Dowser.Client.HTTP` deliberately: retry is orchestration
  around the transport, not a transport concern.

  `resolve/2` turns `opts[:retry]` into a full config (stored on
  `%Dowser.Client.Request{}`); `run/2` drives an arbitrary zero-arity `fun`
  through that policy, sleeping between attempts; `transient?/1` classifies
  the transport's raw `{:error, reason}` payload.

  ## What may be retried

  A retry is only safe when the request cannot already have been applied.
  Three cases, and only the third needs a judgement call:

    * **Never reached the server** — `:econnrefused`, `:nxdomain`,
      `{:failed_connect, _}`, `:enetunreach`, `:ehostunreach`. Nothing ran.
      Always retried.
    * **The server rejected it** — a `:retryable_statuses` response, `429` and
      `503` by default. The server said it did not do the work. Always
      retried.
    * **Ambiguous** — a timeout, a connection dropped mid-flight, or an
      `:ambiguous_statuses` response (`502`/`504`, where a proxy answers for a
      server that may well have applied the request). The request may have
      taken effect, with no answer to say so. Retried **only when the request
      is idempotent**.

  That last case is what makes a retried `POST` duplicate work: a bulk index
  or an auto-id create that timed out may have been applied in full, and
  sending it again writes it twice. So `:idempotent` defaults to the method —
  `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS` and `TRACE` are idempotent, `POST`
  and `PATCH` are not — and a caller who knows better says so per request:

      # a search is a POST, but it writes nothing
      Dowser.Client.post("/posts/_search", query, retry: [idempotent: true])

  ## Options

  `opts[:retry]` accepts:

    * `false` — disables retries (`max_attempts: 1`).
    * a keyword list — merged over the defaults, so a partial override (e.g.
      `retry: [max_attempts: 5]`) only changes the given keys:
        * `:max_attempts` — total attempts, including the first (default `3`).
        * `:max_elapsed_ms` — give up once this much wall-clock time has gone
          into the request, however many attempts are left (default `nil`, no
          budget). A burst of `429`s outlasts three attempts; a budget bounds
          what the caller waits for.
        * `:base_delay_ms` / `:max_delay_ms` — exponential full-jitter backoff
          bounds (default `200` / `2_000`).
        * `:retryable_statuses` — statuses the server rejected the request
          with (default `[429, 503]`).
        * `:ambiguous_statuses` — statuses that may or may not mean the
          request was applied (default `[502, 504]`), retried only when the
          request is idempotent.
        * `:idempotent` — whether re-sending this request is harmless
          (default: derived from the HTTP method).
        * `:respect_retry_after` — obey a `Retry-After` response header, given
          in seconds or as an HTTP date, in place of the computed backoff
          (default `true`).
        * `:max_retry_after_ms` — cap on a `Retry-After` the server asks for
          (default `60_000`). Past the cap the request gives up rather than
          sleeping as asked.
  """

  alias Dowser.Client.Error
  alias Dowser.Client.Response

  ## Typespecs

  @type config :: keyword()

  ## Module attributes

  @default [
    max_attempts: 3,
    max_elapsed_ms: nil,
    base_delay_ms: 200,
    max_delay_ms: 2_000,
    retryable_statuses: [429, 503],
    ambiguous_statuses: [502, 504],
    idempotent: false,
    respect_retry_after: true,
    max_retry_after_ms: 60_000
  ]

  # The request never left, or left and was refused: whatever it would have
  # done, it has not done it.
  @unreachable_reasons [
    :econnrefused,
    :nxdomain,
    :enetunreach,
    :ehostunreach
  ]

  # The connection broke with the request in flight. The server may have
  # applied it and lost the answer.
  @ambiguous_reasons [
    :timeout,
    :etimedout,
    :econnreset,
    :closed,
    # :httpc's own term for a keep-alive session the server closed under us.
    :socket_closed_remotely
  ]

  @idempotent_methods [:get, :head, :put, :delete, :options, :trace]

  ## Public functions

  @doc """
  Resolves `opts[:retry]` into a full retry config, with `:idempotent`
  defaulted from `method` unless the caller set it.

  Returns `{:ok, config}` or `{:error, %Dowser.Client.Error{}}` when
  `opts[:retry]` is neither `false` nor a keyword list.
  """
  @spec resolve(keyword(), atom() | nil) :: {:ok, config()} | {:error, Error.t()}
  def resolve(opts, method \\ nil) do
    default = Keyword.put(@default, :idempotent, method in @idempotent_methods)

    case Keyword.get(opts, :retry, []) do
      false ->
        {:ok, Keyword.put(default, :max_attempts, 1)}

      nil ->
        {:ok, default}

      custom when is_list(custom) ->
        {:ok, Keyword.merge(default, custom)}

      other ->
        {:error, %Error{reason: {:invalid_retry, other}}}
    end
  end

  @doc """
  Runs `fun` up to `config[:max_attempts]` times, retrying as long as the
  result may safely be retried (see the module documentation) and both the
  attempts and the time budget last, sleeping in between.

  Returns `{result, attempts}` — `fun`'s final return value and the number
  of times it was actually called.
  """
  @spec run(config(), (-> term())) :: {term(), pos_integer()}
  def run(config, fun), do: attempt(config, fun, 1, now())

  @doc """
  Whether an adapter's raw `{:error, reason}` payload looks transient — worth
  retrying at all, idempotence aside.
  """
  @spec transient?(term()) :: boolean()
  def transient?(%{reason: reason}), do: transient?(reason)
  def transient?({:failed_connect, _}), do: true
  def transient?(reason) when reason in @unreachable_reasons, do: true
  def transient?(reason) when reason in @ambiguous_reasons, do: true
  def transient?(_reason), do: false

  @doc """
  Whether a failure leaves it unknown whether the request was applied — `false`
  for one that demonstrably never reached the server.

  A non-idempotent request is not retried when this is `true`: that is what
  keeps a timed-out write from being applied twice.
  """
  @spec ambiguous?(term()) :: boolean()
  def ambiguous?(%{reason: reason}), do: ambiguous?(reason)
  def ambiguous?(reason) when reason in @ambiguous_reasons, do: true
  def ambiguous?(_reason), do: false

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

  @doc false
  # The wait before the next attempt: what the server asked for, when it asked
  # and the policy obeys, and the jittered backoff otherwise. `:stop` when the
  # server asks for longer than the policy will wait.
  @spec delay(config(), pos_integer(), term()) :: pos_integer() | :stop
  def delay(config, attempt_number, result) do
    case retry_after(config, result) do
      nil ->
        delay(config, attempt_number)

      ms ->
        if ms > Keyword.fetch!(config, :max_retry_after_ms) do
          :stop
        else
          max(ms, 1)
        end
    end
  end

  ## Private functions

  defp attempt(config, fun, attempt_number, started_at) do
    result = fun.()

    with true <- attempt_number < Keyword.fetch!(config, :max_attempts),
         true <- retry?(result, config),
         delay when is_integer(delay) <- delay(config, attempt_number, result),
         true <- within_budget?(config, started_at, delay) do
      Process.sleep(delay)
      attempt(config, fun, attempt_number + 1, started_at)
    else
      _stop ->
        {result, attempt_number}
    end
  end

  defp retry?({:ok, %Response{status: status}}, config) do
    cond do
      status in Keyword.fetch!(config, :retryable_statuses) ->
        true

      status in Keyword.fetch!(config, :ambiguous_statuses) ->
        idempotent?(config)

      true ->
        false
    end
  end

  defp retry?({:error, reason}, config) do
    cond do
      ambiguous?(reason) ->
        idempotent?(config)

      transient?(reason) ->
        true

      true ->
        false
    end
  end

  defp retry?(_result, _config), do: false

  defp idempotent?(config), do: Keyword.fetch!(config, :idempotent) == true

  defp within_budget?(config, started_at, delay) do
    case Keyword.fetch!(config, :max_elapsed_ms) do
      nil ->
        true

      budget ->
        now() - started_at + delay <= budget
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  ## Private functions — Retry-After

  defp retry_after(config, {:ok, %Response{headers: headers}}) do
    with true <- Keyword.fetch!(config, :respect_retry_after),
         value when is_binary(value) <- Map.get(headers, "retry-after") do
      parse_retry_after(value)
    else
      _absent ->
        nil
    end
  end

  defp retry_after(_config, _result), do: nil

  defp parse_retry_after(value) do
    case value |> String.trim() |> Integer.parse() do
      {seconds, ""} when seconds >= 0 ->
        seconds * 1_000

      _other ->
        from_http_date(value)
    end
  end

  # `Retry-After` may also be an HTTP date; `:httpd_util` parses the formats
  # HTTP allows, and comes with the `:inets` the transport already needs.
  defp from_http_date(value) do
    case :httpd_util.convert_request_date(value |> String.trim() |> String.to_charlist()) do
      :bad_date ->
        nil

      datetime ->
        seconds =
          :calendar.datetime_to_gregorian_seconds(datetime) -
            :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

        max(seconds, 0) * 1_000
    end
  end
end
