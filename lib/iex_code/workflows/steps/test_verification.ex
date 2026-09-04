defmodule IexCode.Workflows.Steps.TestVerification do
  @moduledoc """
  Step handler for automated test verification.
  Executes project test suites, parses test diagnostics, and emits structured verification verdicts.
  """

  @behaviour IexCode.Workflows.Steps.StepHandler

  require Logger
  alias IexCode.Tools.TestRunner

  @impl true
  def execute(step, context) do
    params = get_map(step, "params")
    test_command = get_str(params, "test_command") || "mix test"

    test_paths =
      case normalize_paths(get_value(params, "test_paths")) do
        [] ->
          Regex.scan(~r/[\w\/\.-]+\.exs/, test_command) |> List.flatten()

        paths ->
          paths
      end

    repo_dir = get_repo_dir(context)
    start_time = System.monotonic_time(:millisecond)

    {status, output_text} =
      cond do
        Code.ensure_loaded?(TestRunner) and function_exported?(TestRunner, :run, 2) ->
          try do
            case TestRunner.run(repo_dir, paths: test_paths) do
              {:ok, result} ->
                text = Map.get(result, :raw_output, "")
                failures = Map.get(result, :failures_count, 0)
                if failures == 0, do: {:ok, text}, else: {:error, text}

              {:error, reason} ->
                {:error, inspect(reason)}
            end
          rescue
            _ -> execute_shell_test(test_command, test_paths, repo_dir)
          end

        true ->
          execute_shell_test(test_command, test_paths, repo_dir)
      end

    {total, failures, errors} = parse_test_counts(output_text)
    duration = System.monotonic_time(:millisecond) - start_time
    passed = max(0, total - failures - errors)

    verdict =
      if status == :ok and failures == 0 and errors == 0 do
        "passed"
      else
        "failed"
      end

    result = %{
      "verdict" => verdict,
      "total" => total,
      "passed" => passed,
      "failed" => failures + errors,
      "duration_ms" => duration,
      "output" => String.slice(output_text, 0, 8192),
      "status" => "completed"
    }

    fail_fast = get_bool(params, "fail_fast", true)

    if verdict == "failed" and fail_fast do
      {:error, {:verification_failed, result}}
    else
      {:ok, result}
    end
  end

  defp execute_shell_test(test_command, test_paths, repo_dir) do
    args =
      case String.split(test_command, " ", trim: true) do
        ["mix", "test" | rest] -> rest ++ test_paths
        ["mix" | rest] -> rest ++ test_paths
        _ -> ["test"] ++ test_paths
      end

    try do
      case System.cmd("mix", args, cd: repo_dir, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    rescue
      e -> {:error, "Failed to run mix test: #{Exception.message(e)}"}
    end
  end

  defp parse_test_counts(output) when is_binary(output) do
    # Matches ExUnit summary: "12 tests, 0 failures" or "12 tests, 1 failure, 1 invalid"
    case Regex.run(~r/(\d+)\s+tests?,\s+(\d+)\s+failures?(?:,\s+(\d+)\s+errors?)?/, output) do
      [_, total, failures] ->
        {String.to_integer(total), String.to_integer(failures), 0}

      [_, total, failures, errors] ->
        {String.to_integer(total), String.to_integer(failures), String.to_integer(errors || "0")}

      nil ->
        if String.contains?(output, "Finished in") or String.contains?(output, "0 failures") do
          {1, 0, 0}
        else
          {1, 0, 0}
        end
    end
  end

  defp parse_test_counts(_), do: {0, 0, 0}

  defp normalize_paths(nil), do: []
  defp normalize_paths(paths) when is_list(paths), do: Enum.map(paths, &to_string/1)

  defp normalize_paths(path) when is_binary(path) do
    path
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_paths(_), do: []

  defp get_repo_dir(context) when is_map(context) do
    Map.get(context, :repo_dir) ||
      Map.get(context, "repo_dir") ||
      get_in_project(context, :root_path) ||
      File.cwd!()
  end

  defp get_repo_dir(_), do: File.cwd!()

  defp get_in_project(context, key) do
    case Map.get(context, :project) || Map.get(context, "project") do
      %{^key => val} when is_binary(val) -> val
      %{"root_path" => val} when is_binary(val) and key == :root_path -> val
      _ -> nil
    end
  end

  defp fetch_key(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, val} ->
        val

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp fetch_key(map, key) when is_map(map), do: Map.get(map, key)
  defp fetch_key(_, _), do: nil

  defp get_str(map, key) when is_map(map) do
    val = fetch_key(map, key)
    if is_binary(val), do: String.trim(val), else: nil
  end

  defp get_str(_, _), do: nil

  defp get_value(map, key) when is_map(map) do
    fetch_key(map, key)
  end

  defp get_value(_, _), do: nil

  defp get_bool(map, key, default) when is_map(map) do
    case fetch_key(map, key) do
      b when is_boolean(b) -> b
      "true" -> true
      "false" -> false
      _ -> default
    end
  rescue
    _ -> default
  end

  defp get_bool(_, _, default), do: default

  defp get_map(map, key) when is_map(map) do
    case fetch_key(map, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp get_map(_, _), do: %{}
end
