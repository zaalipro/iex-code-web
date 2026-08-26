defmodule Mix.Tasks.IexCode.Control do
  @moduledoc """
  Reads or controls a durable local run.

      mix iex_code.control [--json] [--request-key KEY] RUN_ID status
      mix iex_code.control [--json] [--request-key KEY] RUN_ID start|pause|resume|cancel|retry
      mix iex_code.control [--json] [--request-key KEY] RUN_ID steer GUIDANCE...

  Pause/resume/steer are persisted for the run's lease-owning daemon to claim;
  the Mix VM never starts a competing worker. Steering is limited to 8 KB.
  """

  use Mix.Task

  alias IexCode.{CLI, Runs}
  alias IexCode.Runs.RunDispatcher

  @shortdoc "Reads or controls one local durable IexCode run"

  @switches [json: :boolean, request_key: :string]
  @aliases [j: :json]
  @actions ~w(status start pause resume cancel retry steer)

  @impl Mix.Task
  def run(argv) do
    CLI.start_app()

    with {opts, args, []} <- OptionParser.parse(argv, strict: @switches, aliases: @aliases),
         {:ok, run_id, action, guidance} <- parse_action(args),
         run when not is_nil(run) <- Runs.get_run(run_id),
         {:ok, result} <- apply_action(run, action, guidance, opts[:request_key]) do
      print_result(result, action, opts[:json])
    else
      {_opts, _args, invalid} when is_list(invalid) ->
        Mix.raise("invalid control options: #{inspect(invalid)}")

      {:error, reason} ->
        Mix.raise(CLI.format_error(reason))

      nil ->
        Mix.raise("run_not_found")
    end
  end

  defp parse_action([run_id, action | rest]) when action in @actions do
    guidance = rest |> Enum.join(" ") |> String.trim()

    cond do
      action == "steer" and guidance == "" -> {:error, :missing_steering_guidance}
      action == "steer" and byte_size(guidance) > 8_000 -> {:error, :steering_guidance_too_large}
      action != "steer" and guidance != "" -> {:error, :unexpected_control_arguments}
      true -> {:ok, run_id, action, guidance}
    end
  end

  defp parse_action(_args),
    do:
      {:error,
       "usage: mix iex_code.control RUN_ID status|start|pause|resume|cancel|retry|steer [GUIDANCE]"}

  defp apply_action(run, action, guidance, request_key) do
    case action do
      "status" -> {:ok, {:run, run}}
      "start" when run.status == "draft" -> wrap_run(RunDispatcher.start_draft_offline(run))
      "start" -> {:error, {:invalid_transition, run.status, "queued"}}
      "pause" -> CLI.enqueue_run_control(run, "pause", %{}, request_key)
      "resume" -> CLI.enqueue_run_control(run, "resume", %{}, request_key)
      "cancel" -> offline_cancel(run) |> wrap_run()
      "retry" -> RunDispatcher.retry_offline(run) |> wrap_run()
      "steer" -> CLI.enqueue_run_control(run, "steer", %{"guidance" => guidance}, request_key)
    end
  end

  defp wrap_run({:ok, run}), do: {:ok, {:run, run}}
  defp wrap_run({:error, _reason} = error), do: error

  defp offline_cancel(%{status: status} = run) when status in ["draft", "queued"],
    do: IexCode.Runs.cancel_unleased_run(run)

  defp offline_cancel(run), do: IexCode.Runs.request_cancellation(run, "local-cli")

  defp print_result({:run, run}, action, true) do
    Mix.shell().info(Jason.encode!(Map.put(CLI.run_json(run), :action, action)))
  end

  defp print_result({:run, run}, action, _json?) do
    Mix.shell().info("#{action}: #{run.id} is #{run.status}")
  end

  defp print_result({run, control}, action, true) do
    payload = %{
      action: action,
      run_id: run.id,
      run_status: run.status,
      control_id: control.id,
      control_status: control.status,
      control_sequence: control.sequence,
      request_key: control.idempotency_key
    }

    Mix.shell().info(Jason.encode!(payload))
  end

  defp print_result({run, control}, action, _json?) do
    Mix.shell().info(
      "#{action}: control #{control.id} is #{control.status} for run #{run.id} (#{run.status}) request=#{control.idempotency_key}"
    )
  end
end
