defmodule IexCode.Workflows.Steps.SecurityAudit do
  @moduledoc """
  Step handler for security and safety audits.
  Inspects code changes, diffs, and configuration for hardcoded secrets,
  prohibited operations, and safety policy violations.
  """

  @behaviour IexCode.Workflows.Steps.StepHandler

  require Logger
  alias IexCode.Tools.Git

  @sensitive_files ~w(.env id_rsa id_ed25519 credentials.json service_account.json)

  defp sensitive_patterns do
    [
      {~r/sk-[a-zA-Z0-9]{32,}/, "OpenAI API secret key pattern detected", :high},
      {~r/AKIA[0-9A-Z]{16}/, "AWS Access Key ID detected", :critical},
      {~r/-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/, "Private key file or certificate detected",
       :critical},
      {~r/ghp_[a-zA-Z0-9]{36}/, "GitHub Personal Access Token detected", :high},
      {~r/password\s*[:=]\s*["'][^"']{6,}["']/i, "Hardcoded plaintext password detected", :high},
      {~r/:os\.cmd\s*\(/, "Unsandboxed :os.cmd invocation detected", :medium},
      {~r/Code\.eval_string\s*\(/, "Dynamic Code.eval_string execution detected", :high}
    ]
  end

  @impl true
  def execute(step, context) do
    params = get_map(step, "params")
    repo_dir = get_repo_dir(context)
    start_time = System.monotonic_time(:millisecond)

    diff_content =
      case get_str(params, "diff") do
        d when is_binary(d) and d != "" ->
          d

        _ ->
          fetch_git_diff(repo_dir)
      end

    files = normalize_files(get_value(params, "files"))
    violations = scan_for_violations(diff_content, files)
    risk_score = compute_risk_score(violations)

    verdict =
      if risk_score >= 30 or Enum.any?(violations, &(&1["severity"] in ["high", "critical"])) do
        "flagged"
      else
        "approved"
      end

    duration = System.monotonic_time(:millisecond) - start_time

    summary =
      if violations == [] do
        "Security audit passed cleanly. Zero credential leaks or critical violations detected."
      else
        "Security audit flagged #{length(violations)} potential issue(s) with risk score #{risk_score}/100."
      end

    output = %{
      "verdict" => verdict,
      "risk_score" => risk_score,
      "violations" => violations,
      "summary" => summary,
      "duration_ms" => duration,
      "status" => "completed"
    }

    strict = get_bool(params, "strict", false)

    if verdict == "flagged" and strict do
      {:error, {:security_audit_failed, output}}
    else
      {:ok, output}
    end
  end

  defp fetch_git_diff(repo_dir) do
    if Code.ensure_loaded?(Git) and function_exported?(Git, :diff, 2) do
      case Git.diff(repo_dir, staged: true) do
        {:ok, diff} when is_binary(diff) and diff != "" ->
          diff

        _ ->
          case Git.diff(repo_dir) do
            {:ok, diff} when is_binary(diff) -> diff
            _ -> ""
          end
      end
    else
      ""
    end
  end

  defp scan_for_violations(diff, files) do
    diff_violations =
      Enum.flat_map(sensitive_patterns(), fn {regex, description, severity} ->
        if Regex.match?(regex, diff) do
          [
            %{
              "description" => description,
              "severity" => to_string(severity),
              "type" => "pattern_match"
            }
          ]
        else
          []
        end
      end)

    file_violations =
      Enum.flat_map(files, fn file ->
        base = Path.basename(file)

        if base in @sensitive_files do
          [
            %{
              "description" => "Sensitive file touched: #{file}",
              "severity" => "critical",
              "type" => "sensitive_file"
            }
          ]
        else
          []
        end
      end)

    diff_violations ++ file_violations
  end

  defp compute_risk_score(violations) do
    Enum.reduce(violations, 0, fn v, acc ->
      weight =
        case v["severity"] do
          "critical" -> 50
          "high" -> 30
          "medium" -> 15
          _ -> 5
        end

      min(100, acc + weight)
    end)
  end

  defp normalize_files(nil), do: []
  defp normalize_files(files) when is_list(files), do: Enum.map(files, &to_string/1)

  defp normalize_files(file) when is_binary(file) do
    file
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_files(_), do: []

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
