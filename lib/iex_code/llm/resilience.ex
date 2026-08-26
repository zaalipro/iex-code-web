defmodule IexCode.LLM.Resilience do
  @default_deadline_ms 55_000
  @breaker_threshold 3
  @breaker_cooldown_ms 30_000

  @moduledoc """
  Resilience and auto-retry engine with exponential backoff, jitter,
  network timeout classification, and fallback provider routing.

  ## Error classification
  Structured provider errors (`{:error, %{status: int, body: binary, kind: atom}}`
  per the LLM contract) are classified by `:kind` first: `:rate_limit`, `:server`,
  and `:network` are retryable; `:auth` and `:bad_request` are not. Legacy string
  and bare-status errors keep working via fallback matching.

  ## Retry-After
  When a failed attempt reports a `Retry-After` hint — either as
  `%{retry_after_ms: ms}` or a `retry-after` header in `%{headers: headers}` —
  the sleep never goes below the server-requested delay.

  ## Stream resets
  When an `:on_chunk` callback is provided, a single
  `on_chunk.({:stream_reset, attempt})` sentinel is emitted immediately before a
  retried attempt or a fallback provider is invoked, so UI consumers can clear
  duplicated partial text from the aborted attempt. Consumers must ignore unknown
  chunk shapes.

  ## Deadline
  Total retry wall-clock is capped by the `:deadline_ms` option
  (default: `#{@default_deadline_ms}`), kept below the typical 60s operation
  deadline. `with_fallback/2` shares one deadline across the whole provider chain.

  ## Circuit breaker
  After `#{@breaker_threshold}` consecutive provider failures (per provider name,
  ETS-backed), further calls to that provider fail fast with
  `{:error, {:circuit_open, ms_remaining}}` for a `#{@breaker_cooldown_ms}ms`
  cooldown. A success resets the counter.
  """
  require Logger

  @default_max_retries 3
  @default_base_backoff_ms 500
  @default_max_backoff_ms 10_000
  @default_retryable_statuses [429, 500, 502, 503, 504]

  @doc """
  Executes `fun` with exponential backoff and jitter upon retryable errors.

  ## Options
  - `:max_retries` (integer, default: 3)
  - `:base_backoff_ms` (integer, default: 500)
  - `:max_backoff_ms` (integer, default: 10_000)
  - `:retryable_statuses` (list of integers, default: [429, 500, 502, 503, 504])
  - `:jitter` (:full | :equal | :none, default: :full)
  - `:on_retry` (fn attempt, reason, sleep_ms -> any(), default: no-op)
  - `:on_chunk` (fn chunk -> any(), default: no-op) - receives a
    `{:stream_reset, attempt}` sentinel before each retried attempt
  - `:deadline_ms` (integer, default: 55_000) - total wall-clock budget; retries
    that would exceed it are abandoned and the last error returned
  """
  @spec with_retry((-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    cfg = %{
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      base_backoff: Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms),
      max_backoff: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
      retryable_statuses: Keyword.get(opts, :retryable_statuses, @default_retryable_statuses),
      jitter: Keyword.get(opts, :jitter, :full),
      on_retry: Keyword.get(opts, :on_retry, fn _attempt, _reason, _sleep -> :ok end),
      on_chunk: Keyword.get(opts, :on_chunk, fn _event -> :ok end),
      deadline:
        System.monotonic_time(:millisecond) +
          Keyword.get(opts, :deadline_ms, @default_deadline_ms)
    }

    do_retry(fun, 1, cfg)
  end

  @doc """
  Executes a sequence of provider functions in fallback order.
  Each provider is attempted with `with_retry/2`. The `:deadline_ms` budget is
  shared across the whole chain, and per-provider circuit-breaker state is
  tracked by provider name.

  ## Options
  Same as `with_retry/2`, plus `:on_chunk` is also used to emit the
  `{:stream_reset, attempt}` sentinel when routing to a fallback provider.

  ## Example
      providers = [
        {"openai", fn -> OpenAI.chat(...) end},
        {"anthropic", fn -> Anthropic.chat(...) end}
      ]
      {:ok, result, meta} = Resilience.with_fallback(providers)
  """
  @spec with_fallback([{name :: String.t(), (-> {:ok, term()} | {:error, term()})}], keyword()) ::
          {:ok, result :: term(), meta :: %{provider: String.t(), fallback_used?: boolean()}}
          | {:error, {:all_providers_failed, list()}}
  def with_fallback(providers, opts \\ []) when is_list(providers) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :deadline_ms, @default_deadline_ms)

    do_fallback(providers, opts, [], deadline, 0)
  end

  # --- Internal Helpers ---

  defp do_retry(fun, attempt, cfg) do
    try do
      case fun.() do
        {:ok, _} = success ->
          success

        {:error, reason} = err ->
          if attempt <= cfg.max_retries and retryable_error?(reason, cfg.retryable_statuses) do
            retry(fun, attempt, reason, cfg, err)
          else
            err
          end
      end
    rescue
      ex ->
        if attempt <= cfg.max_retries and retryable_exception?(ex) do
          retry(fun, attempt, ex, cfg, {:error, {:exception, ex}})
        else
          {:error, {:exception, ex}}
        end
    end
  end

  defp retry(fun, attempt, reason, cfg, err) do
    computed = compute_backoff(attempt, cfg.base_backoff, cfg.max_backoff, cfg.jitter)
    sleep_ms = sleep_for(reason, computed)
    now = System.monotonic_time(:millisecond)

    if now + sleep_ms >= cfg.deadline do
      Logger.warning(
        "[Resilience] Retry deadline exceeded before attempt #{attempt}/#{cfg.max_retries}; giving up due to: #{inspect(reason)}"
      )

      err
    else
      Logger.warning(
        "[Resilience] Retry #{attempt}/#{cfg.max_retries} in #{sleep_ms}ms due to: #{inspect(reason)}"
      )

      cfg.on_retry.(attempt, reason, sleep_ms)
      if sleep_ms > 0, do: :timer.sleep(sleep_ms)

      cfg.on_chunk.({:stream_reset, attempt})
      do_retry(fun, attempt + 1, cfg)
    end
  end

  # Server-requested Retry-After never shortens the computed backoff.
  defp sleep_for(reason, computed) do
    case retry_after_ms(reason) do
      nil -> computed
      ms -> max(ms, computed)
    end
  end

  defp retry_after_ms(%{retry_after_ms: ms}) when is_integer(ms) and ms > 0,
    do: min(ms, @default_max_backoff_ms)

  defp retry_after_ms(%{headers: headers}) when is_list(headers) or is_map(headers),
    do: header_retry_after(headers)

  defp retry_after_ms(_), do: nil

  defp header_retry_after(headers) do
    Enum.find_value(headers, fn
      {k, v} ->
        if String.downcase(to_string(k)) == "retry-after", do: parse_retry_after(v)

      _ ->
        nil
    end)
  end

  defp parse_retry_after(value) do
    case Integer.parse(to_string(value)) do
      {secs, _} when secs > 0 -> min(secs * 1000, @default_max_backoff_ms)
      _ -> nil
    end
  end

  defp do_fallback([], _opts, errors, _deadline, _attempt) do
    {:error, {:all_providers_failed, Enum.reverse(errors)}}
  end

  defp do_fallback([{provider_name, provider_fn} | rest], opts, errors, deadline, attempt) do
    on_chunk = Keyword.get(opts, :on_chunk, fn _event -> :ok end)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        Logger.warning(
          "[Resilience] Deadline exceeded before provider #{provider_name}; aborting fallback chain."
        )

        {:error,
         {:all_providers_failed, Enum.reverse([{provider_name, :deadline_exceeded} | errors])}}

      circuit_open?(provider_name) ->
        Logger.warning(
          "[Resilience] Circuit open for #{provider_name}; failing fast to next provider."
        )

        do_fallback(
          rest,
          opts,
          [{provider_name, {:circuit_open, @breaker_cooldown_ms}} | errors],
          deadline,
          attempt + 1
        )

      true ->
        retry_opts = Keyword.put(opts, :deadline_ms, remaining)

        case with_retry(provider_fn, retry_opts) do
          {:ok, result} ->
            record_success(provider_name)
            {:ok, result, %{provider: provider_name, fallback_used?: errors != []}}

          {:error, reason} ->
            record_failure(provider_name)

            Logger.warning(
              "[Resilience] Provider #{provider_name} failed: #{inspect(reason)}. Routing to fallback."
            )

            unless rest == [] do
              on_chunk.({:stream_reset, attempt + 1})
            end

            do_fallback(rest, opts, [{provider_name, reason} | errors], deadline, attempt + 1)
        end
    end
  end

  # --- Circuit Breaker (ETS-backed, keyed by provider name) ---

  defp breaker_table do
    if :ets.whereis(__MODULE__) == :undefined do
      # Table is owned by whichever process created it; if that process exits the
      # table dies and is lazily recreated here. State loss on owner exit is
      # acceptable (breakers simply reset).
      try do
        :ets.new(__MODULE__, [:named_table, :public, :set, {:read_concurrency, true}])
      rescue
        # Lost a creation race with another process; the table already exists.
        ArgumentError -> :ok
      end
    end

    __MODULE__
  end

  # Runs an ETS operation against the breaker table, retrying once so a table
  # whose owner died is recreated by breaker_table/0 and the op self-heals.
  defp ets_op(fun) do
    fun.(breaker_table())
  rescue
    ArgumentError -> fun.(breaker_table())
  end

  defp circuit_open?(provider) do
    case ets_op(&:ets.lookup(&1, provider)) do
      [{_, _failures, opened_at}] when opened_at != nil ->
        now = System.monotonic_time(:millisecond)

        if now - opened_at < @breaker_cooldown_ms do
          true
        else
          # Cooldown elapsed: half-open, allow attempts again.
          ets_op(&:ets.insert(&1, {provider, 0, nil}))
          false
        end

      _ ->
        false
    end
  end

  defp record_success(provider) do
    ets_op(&:ets.insert(&1, {provider, 0, nil}))
  end

  defp record_failure(provider) do
    failures =
      case ets_op(&:ets.lookup(&1, provider)) do
        [{_, count, _}] -> count + 1
        [] -> 1
      end

    if failures >= @breaker_threshold do
      Logger.warning(
        "[Resilience] Circuit opened for #{provider} after #{failures} consecutive failures; cooling down for #{@breaker_cooldown_ms}ms."
      )

      ets_op(&:ets.insert(&1, {provider, failures, System.monotonic_time(:millisecond)}))
    else
      ets_op(&:ets.insert(&1, {provider, failures, nil}))
    end
  end

  @doc """
  Calculates exponential backoff with jitter.
  """
  def compute_backoff(_attempt, 0, _max_b, _jitter), do: 0

  def compute_backoff(attempt, base, max_b, :full) do
    exp = min(max_b, round(base * :math.pow(2, attempt - 1)))
    if exp <= 0, do: 0, else: Enum.random(0..exp)
  end

  def compute_backoff(attempt, base, max_b, :equal) do
    exp = min(max_b, round(base * :math.pow(2, attempt - 1)))
    half = div(exp, 2)
    if half <= 0, do: 0, else: half + Enum.random(0..half)
  end

  def compute_backoff(attempt, base, max_b, :none) do
    min(max_b, round(base * :math.pow(2, attempt - 1)))
  end

  @doc """
  Determines if an error reason represents a transient/retryable condition.
  Structured `%{status: _, kind: _}` maps are classified by `:kind` first;
  legacy string and bare-status formats remain supported as fallbacks.
  """
  def retryable_error?(%{kind: :rate_limit}, _), do: true
  def retryable_error?(%{kind: :server}, _), do: true
  def retryable_error?(%{kind: :network}, _), do: true
  def retryable_error?(%{kind: :auth}, _), do: false
  def retryable_error?(%{kind: :bad_request}, _), do: false

  def retryable_error?(%{status: status}, statuses) when is_integer(status),
    do: status in statuses

  def retryable_error?({:status, status}, statuses) when is_integer(status),
    do: status in statuses

  def retryable_error?(status, statuses) when is_integer(status), do: status in statuses

  def retryable_error?("OpenAI API returned status " <> rest, statuses) do
    case Integer.parse(rest) do
      {code, _} -> code in statuses
      _ -> false
    end
  end

  def retryable_error?("Anthropic API returned status " <> rest, statuses) do
    case Integer.parse(rest) do
      {code, _} -> code in statuses
      _ -> false
    end
  end

  def retryable_error?(:timeout, _), do: true
  def retryable_error?(:connect_timeout, _), do: true
  def retryable_error?(:recv_timeout, _), do: true
  def retryable_error?(:closed, _), do: true
  def retryable_error?(:econnrefused, _), do: true
  def retryable_error?(%Req.TransportError{}, _), do: true
  def retryable_error?(%{reason: r}, statuses) when is_atom(r), do: retryable_error?(r, statuses)
  def retryable_error?({:error, r}, statuses), do: retryable_error?(r, statuses)
  def retryable_error?(_, _), do: false

  def retryable_exception?(%Req.TransportError{}), do: true
  def retryable_exception?(%Mint.TransportError{}), do: true
  def retryable_exception?(_), do: false
end
