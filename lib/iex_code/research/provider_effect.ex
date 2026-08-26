defmodule IexCode.Research.ProviderEffect do
  @moduledoc """
  At-most-once boundary for research provider calls.

  The durable intent and its budget reservation are committed before the callback
  can run. Callback closures may capture credentials, but neither the closure nor
  callback values are written to the command ledger. Ambiguous callback outcomes
  are terminal and charge the complete reservation.

  Completed response bodies are stored through the same bounded, secret-safe
  settlement transaction. A retry of the same logical run step verifies and
  returns that body with `replayed?: true` without invoking the callback.
  """

  alias IexCode.Research.ProviderBudget
  alias IexCode.Runs.{DagPayload, RunCommand, RunStepAttempt}

  @max_operation_bytes 120
  @max_request_bytes 64_000
  @default_response_bytes 256_000
  @max_response_bytes 256_000
  @default_timeout_ms 30_000
  @max_timeout_ms 300_000
  @poll_ms 25
  @dimensions ~w(requests input_tokens output_tokens cost_cents)

  @doc """
  Invokes a zero-arity callback behind a durable, deterministic provider intent.

  A successful callback must return `{:ok, response_map, usage_map}`. A provider
  rejection with known usage returns `{:error, stable_atom, usage_map}`. Options
  accept `:cancelled?` (arity zero), `:checkpoint` (arity two), `:timeout_ms`,
  `:max_response_bytes`, and `:progress`. The hard response ceiling cannot be
  widened beyond 256KB.
  """
  def invoke(
        attempt,
        owner,
        run_generation,
        step_generation,
        operation,
        request_descriptor,
        estimate,
        callback,
        opts \\ []
      )

  def invoke(
        %RunStepAttempt{} = attempt,
        owner,
        run_generation,
        step_generation,
        operation,
        request_descriptor,
        estimate,
        callback,
        opts
      )
      when is_binary(owner) and owner != "" and is_integer(run_generation) and
             is_integer(step_generation) and is_binary(operation) and
             is_map(request_descriptor) and is_map(estimate) and is_function(callback, 0) and
             is_list(opts) do
    with :ok <- validate_operation(operation),
         {:ok, request_descriptor} <-
           DagPayload.validate(request_descriptor, max_bytes: @max_request_bytes),
         {:ok, request_digest} <- DagPayload.digest(request_descriptor),
         {:ok, config} <- config(opts),
         {:ok, effect_digest} <- effect_digest(attempt, operation, request_digest),
         {:ok, claim} <-
           ProviderBudget.reserve_with_status(
             attempt,
             owner,
             run_generation,
             step_generation,
             "provider-effect:" <> effect_digest,
             estimate
           ) do
      if claim.created? do
        execute_created(
          claim.reservation,
          owner,
          run_generation,
          step_generation,
          effect_digest,
          callback,
          config
        )
      else
        replay_result(claim.reservation, effect_digest)
      end
    else
      {:error, reason} -> {:error, normalize_preflight_error(reason)}
    end
  end

  def invoke(
        _attempt,
        _owner,
        _run_generation,
        _step_generation,
        _operation,
        _request,
        _estimate,
        _callback,
        _opts
      ),
      do: {:error, :invalid_provider_effect}

  @doc "Marks abandoned claimed provider effects uncertain without invoking callbacks."
  def reconcile_claimed(opts \\ []), do: ProviderBudget.reconcile_claimed(opts)

  defp execute_created(
         reservation,
         owner,
         run_generation,
         step_generation,
         effect_digest,
         callback,
         config
       ) do
    case cancellation_state(config.cancelled?) do
      :cancelled ->
        release_before_call(
          reservation,
          owner,
          run_generation,
          step_generation,
          :not_sent,
          :cancelled
        )

      :invalid ->
        release_before_call(
          reservation,
          owner,
          run_generation,
          step_generation,
          :preflight_rejected,
          :invalid_provider_effect_context
        )

      :active ->
        checkpoint_and_execute(
          reservation,
          owner,
          run_generation,
          step_generation,
          effect_digest,
          callback,
          config
        )
    end
  end

  defp checkpoint_and_execute(
         reservation,
         owner,
         run_generation,
         step_generation,
         effect_digest,
         callback,
         config
       ) do
    payload = %{"effect_digest" => effect_digest, "phase" => "before_external_effect"}

    case safe_checkpoint(config.checkpoint, payload, config.progress) do
      :ok ->
        case cancellation_state(config.cancelled?) do
          :active ->
            start_callback(
              reservation,
              owner,
              run_generation,
              step_generation,
              effect_digest,
              callback,
              config
            )

          :cancelled ->
            release_before_call(
              reservation,
              owner,
              run_generation,
              step_generation,
              :not_sent,
              :cancelled
            )

          :invalid ->
            release_before_call(
              reservation,
              owner,
              run_generation,
              step_generation,
              :preflight_rejected,
              :invalid_provider_effect_context
            )
        end

      {:error, :cancelled} ->
        release_before_call(
          reservation,
          owner,
          run_generation,
          step_generation,
          :not_sent,
          :cancelled
        )

      {:error, :checkpoint_failed} ->
        release_before_call(
          reservation,
          owner,
          run_generation,
          step_generation,
          :preflight_rejected,
          :checkpoint_failed
        )
    end
  end

  defp start_callback(
         reservation,
         owner,
         run_generation,
         step_generation,
         effect_digest,
         callback,
         config
       ) do
    case supervised_task(callback) do
      {:ok, task} ->
        deadline = System.monotonic_time(:millisecond) + config.timeout_ms

        case await_callback(task, config.cancelled?, deadline) do
          {:returned, callback_result} ->
            finish_callback(
              callback_result,
              reservation,
              owner,
              run_generation,
              step_generation,
              effect_digest,
              config.max_response_bytes
            )

          :uncertain ->
            settle_uncertain(
              reservation,
              owner,
              run_generation,
              step_generation,
              effect_digest
            )
        end

      {:error, :task_unavailable} ->
        release_before_call(
          reservation,
          owner,
          run_generation,
          step_generation,
          :preflight_rejected,
          :provider_executor_unavailable
        )
    end
  end

  defp finish_callback(
         callback_result,
         reservation,
         owner,
         run_generation,
         step_generation,
         effect_digest,
         max_response_bytes
       ) do
    case callback_result do
      {:ok, response, usage} when is_map(response) and is_map(usage) ->
        with {:ok, usage} <- normalize_usage(usage),
             {:ok, response} <- DagPayload.validate(response, max_bytes: max_response_bytes),
             {:ok, response_digest} <- DagPayload.digest(response) do
          receipt = %{
            "effect_digest" => effect_digest,
            "phase" => "completed",
            "response_digest" => response_digest
          }

          case ProviderBudget.settle(
                 reservation,
                 owner,
                 run_generation,
                 step_generation,
                 usage,
                 outcome: :completed,
                 receipt: receipt,
                 payload: response
               ) do
            {:ok, settled} ->
              {:ok,
               completed_receipt(
                 settled.reservation,
                 effect_digest,
                 response,
                 response_digest,
                 usage,
                 false
               )}

            {:error, _reason} ->
              settle_uncertain(
                reservation,
                owner,
                run_generation,
                step_generation,
                effect_digest
              )
          end
        else
          {:error, _reason} ->
            settle_uncertain(
              reservation,
              owner,
              run_generation,
              step_generation,
              effect_digest
            )
        end

      {:error, stable_code, usage} when is_atom(stable_code) and is_map(usage) ->
        case normalize_usage(usage) do
          {:ok, usage} ->
            receipt = %{"effect_digest" => effect_digest, "phase" => "failed"}

            case ProviderBudget.settle(
                   reservation,
                   owner,
                   run_generation,
                   step_generation,
                   usage,
                   outcome: :failed,
                   receipt: receipt
                 ) do
              {:ok, _settled} ->
                {:error, stable_code}

              {:error, _reason} ->
                settle_uncertain(
                  reservation,
                  owner,
                  run_generation,
                  step_generation,
                  effect_digest
                )
            end

          {:error, _reason} ->
            settle_uncertain(
              reservation,
              owner,
              run_generation,
              step_generation,
              effect_digest
            )
        end

      _other ->
        settle_uncertain(
          reservation,
          owner,
          run_generation,
          step_generation,
          effect_digest
        )
    end
  end

  defp supervised_task(callback) do
    task =
      Task.Supervisor.async_nolink(IexCode.TaskSupervisor, fn ->
        try do
          {:callback_return, callback.()}
        rescue
          _exception -> :callback_failed
        catch
          _kind, _reason -> :callback_failed
        end
      end)

    {:ok, task}
  rescue
    _exception -> {:error, :task_unavailable}
  catch
    _kind, _reason -> {:error, :task_unavailable}
  end

  defp await_callback(task, cancelled?, deadline) do
    case cancellation_state(cancelled?) do
      :active ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          terminate_task(task)
          :uncertain
        else
          case Task.yield(task, min(remaining, @poll_ms)) do
            {:ok, {:callback_return, value}} ->
              case cancellation_state(cancelled?) do
                :active -> {:returned, value}
                _cancelled_or_invalid -> :uncertain
              end

            {:ok, :callback_failed} ->
              :uncertain

            {:exit, _reason} ->
              :uncertain

            nil ->
              await_callback(task, cancelled?, deadline)
          end
        end

      _cancelled_or_invalid ->
        terminate_task(task)
        :uncertain
    end
  end

  defp terminate_task(task) do
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp settle_uncertain(
         reservation,
         owner,
         run_generation,
         step_generation,
         effect_digest
       ) do
    receipt = %{"effect_digest" => effect_digest, "phase" => "callback_started"}

    case ProviderBudget.settle(
           reservation,
           owner,
           run_generation,
           step_generation,
           zero_usage(),
           outcome: :uncertain,
           receipt: receipt
         ) do
      {:ok, _settled} -> {:error, :external_effect_uncertain}
      {:error, _reason} -> {:error, :external_effect_unsettled}
    end
  end

  defp release_before_call(
         reservation,
         owner,
         run_generation,
         step_generation,
         reason,
         nominal_error
       ) do
    case ProviderBudget.release(reservation, owner, run_generation, step_generation, reason) do
      {:ok, _released} -> {:error, nominal_error}
      {:error, _reason} -> {:error, :external_effect_release_failed}
    end
  end

  defp replay_result(%RunCommand{status: "uncertain"}, _effect_digest),
    do: {:error, :external_effect_uncertain}

  defp replay_result(%RunCommand{status: "claimed"}, _effect_digest),
    do: {:error, :external_effect_ambiguous}

  defp replay_result(%RunCommand{status: "failed"}, _effect_digest),
    do: {:error, :provider_request_failed}

  defp replay_result(%RunCommand{status: "cancelled"}, _effect_digest),
    do: {:error, :external_effect_not_sent}

  defp replay_result(%RunCommand{status: "completed"} = reservation, effect_digest) do
    with {:ok,
          %{
            "actual" => usage,
            "digest" => settlement_digest,
            "outcome" => "completed",
            "payload" => payload,
            "payload_digest" => payload_digest,
            "receipt" => receipt
          }} <-
           Jason.decode(reservation.output || ""),
         %{"effect_digest" => ^effect_digest, "response_digest" => response_digest} <- receipt,
         true <- is_binary(response_digest),
         {:ok, payload} <- DagPayload.validate(payload, max_bytes: @max_response_bytes),
         {:ok, verified_payload_digest} <- DagPayload.digest(payload),
         true <- verified_payload_digest == payload_digest,
         true <- verified_payload_digest == response_digest,
         {:ok, verified_settlement_digest} <-
           DagPayload.digest(%{
             "actual" => usage,
             "outcome" => "completed",
             "payload_digest" => payload_digest,
             "receipt" => receipt
           }),
         true <- verified_settlement_digest == settlement_digest do
      {:ok,
       completed_receipt(
         reservation,
         effect_digest,
         payload,
         response_digest,
         atomize_usage(usage),
         true
       )}
    else
      _other -> {:error, :invalid_provider_effect_receipt}
    end
  end

  defp replay_result(_reservation, _effect_digest),
    do: {:error, :invalid_provider_effect_state}

  defp completed_receipt(
         reservation,
         effect_digest,
         response,
         response_digest,
         usage,
         replayed?
       ) do
    %{
      effect_digest: effect_digest,
      replayed?: replayed?,
      reservation: reservation,
      response: response,
      response_digest: response_digest,
      status: :completed,
      usage: usage
    }
  end

  defp effect_digest(attempt, operation, request_digest) do
    DagPayload.digest(%{
      "run_id" => attempt.run_id,
      "run_step_id" => attempt.run_step_id,
      "run_attempt" => attempt.run_attempt,
      "manifest_hash" => attempt.manifest_hash,
      "handler_kind" => attempt.handler_kind,
      "handler_version" => attempt.handler_version,
      "operation" => operation,
      "request_digest" => request_digest,
      "version" => 1
    })
  end

  defp validate_operation(operation) do
    if byte_size(operation) in 1..@max_operation_bytes and String.valid?(operation) and
         String.match?(operation, ~r/^[a-z0-9][a-z0-9._:-]*$/) do
      :ok
    else
      {:error, :invalid_provider_operation}
    end
  end

  defp config(opts) do
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)
    checkpoint = Keyword.get(opts, :checkpoint, fn _payload, _progress -> :ok end)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_response_bytes)
    progress = Keyword.get(opts, :progress, 0)

    if is_function(cancelled?, 0) and is_function(checkpoint, 2) and
         is_integer(timeout_ms) and timeout_ms in 1..@max_timeout_ms and
         is_integer(max_response_bytes) and max_response_bytes in 1..@max_response_bytes and
         is_integer(progress) and progress in 0..100 do
      {:ok,
       %{
         cancelled?: cancelled?,
         checkpoint: checkpoint,
         max_response_bytes: max_response_bytes,
         progress: progress,
         timeout_ms: timeout_ms
       }}
    else
      {:error, :invalid_provider_effect_options}
    end
  end

  defp safe_checkpoint(callback, payload, progress) do
    case callback.(payload, progress) do
      :ok -> :ok
      {:ok, _receipt} -> :ok
      {:error, :cancelled} -> {:error, :cancelled}
      _other -> {:error, :checkpoint_failed}
    end
  rescue
    _exception -> {:error, :checkpoint_failed}
  catch
    _kind, _reason -> {:error, :checkpoint_failed}
  end

  defp cancellation_state(callback) do
    case callback.() do
      false -> :active
      true -> :cancelled
      _other -> :invalid
    end
  rescue
    _exception -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  defp normalize_usage(usage) do
    keys =
      Enum.map(Map.keys(usage), fn key ->
        if is_atom(key), do: Atom.to_string(key), else: key
      end)

    cond do
      Enum.any?(keys, &(&1 not in @dimensions)) ->
        {:error, :invalid_provider_usage}

      true ->
        normalized =
          Map.new(@dimensions, fn dimension ->
            atom = String.to_existing_atom(dimension)
            {atom, Map.get(usage, atom, Map.get(usage, dimension, 0))}
          end)

        if Enum.all?(normalized, fn {_key, value} ->
             is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
           end) do
          {:ok, normalized}
        else
          {:error, :invalid_provider_usage}
        end
    end
  end

  defp atomize_usage(usage) when is_map(usage) do
    Map.new(@dimensions, fn dimension ->
      {String.to_existing_atom(dimension), Map.get(usage, dimension, 0)}
    end)
  end

  defp zero_usage,
    do: %{requests: 0, input_tokens: 0, output_tokens: 0, cost_cents: 0}

  defp normalize_preflight_error({:payload_too_large, _maximum}),
    do: :provider_request_too_large

  defp normalize_preflight_error(:secret_payload_forbidden),
    do: :provider_request_contains_secret

  defp normalize_preflight_error(reason), do: reason
end
