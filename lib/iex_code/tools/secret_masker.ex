defmodule IexCode.Tools.SecretMasker do
  @moduledoc """
  Secret redaction engine and environment sandbox manager.

  Redacts known sensitive tokens, host credentials, and standard API key patterns
  from command outputs, terminal buffers, and tool results.
  """

  @redacted_placeholder "[REDACTED_SECRET]"
  @sensitive_env_keys ~w(KEY SECRET TOKEN PASSWORD PASS CREDENTIAL AUTH PRIVATE DATABASE_URL)
  @base_isolated_keys ~w(TERM COLORTERM LANG PATH HOME TMPDIR USER)

  defp secret_patterns do
    [
      # OpenAI keys (standard and project)
      ~r/sk-(?:proj-)?[a-zA-Z0-9_\-]{20,}/,
      # Anthropic keys
      ~r/sk-ant-[a-zA-Z0-9_\-]{20,}/,
      # GitHub personal access and fine-grained tokens
      ~r/gh[pousr]_[A-Za-z0-9_]{36,}/,
      ~r/github_pat_[A-Za-z0-9_]{40,}/,
      # AWS Access Key IDs
      ~r/AKIA[0-9A-Z]{16}/,
      # Slack tokens
      ~r/xox[baprs]-[0-9a-zA-Z\-]{20,}/
    ]
  end

  @doc """
  Scrubs secrets from output text by redacting known secret strings and matching regex patterns.
  """
  @spec scrub(any(), list(String.t())) :: String.t()
  def scrub(output, known_secrets \\ [])

  def scrub(nil, _known_secrets), do: ""

  def scrub(output, known_secrets) when is_binary(output) do
    output
    |> scrub_known_secrets(known_secrets)
    |> scrub_bearer_tokens()
    |> scrub_env_assignments()
    |> scrub_regex_patterns()
  end

  def scrub(other, known_secrets) do
    scrub(to_string(other), known_secrets)
  end

  @doc """
  Redacts an individual token from a target string.
  """
  @spec redact_token(String.t(), String.t()) :: String.t()
  def redact_token(target, token) when is_binary(target) and is_binary(token) do
    if byte_size(token) >= 4 do
      String.replace(target, token, @redacted_placeholder)
    else
      target
    end
  end

  def redact_token(target, _), do: target

  @doc """
  Builds a sanitized environment map suitable for Port execution under the specified sandbox mode.
  Modes:
    * `"isolated"`: Passes only base system variables, workspace root, and custom env vars.
    * `"inherit_filtered"`: Passes host environment minus sensitive credentials, plus custom vars.
    * `"passthrough"`: Passes full host environment plus custom vars.
  """
  @spec build_sandbox_env(String.t(), map(), String.t() | nil) :: %{String.t() => String.t()}
  def build_sandbox_env(mode, custom_env_vars \\ %{}, project_root \\ nil) do
    host_env = System.get_env()
    custom = stringify_env_map(custom_env_vars)
    root = project_root || host_env["WORKSPACE_ROOT"] || File.cwd!()

    base_map =
      case mode do
        "isolated" ->
          host_env
          |> Map.take(@base_isolated_keys)
          |> Map.put("WORKSPACE_ROOT", root)

        "inherit_filtered" ->
          host_env
          |> Enum.reject(fn {key, _val} -> sensitive_key?(key) end)
          |> Map.new()
          |> Map.put("WORKSPACE_ROOT", root)

        _passthrough ->
          host_env
          |> Map.put("WORKSPACE_ROOT", root)
      end

    Map.merge(base_map, custom)
  end

  @doc """
  Converts an environment map into the charlist tuple list expected by Port.open `env:` option.
  """
  @spec to_port_env(map()) :: list({charlist(), charlist()})
  def to_port_env(env_map) when is_map(env_map) do
    Enum.map(env_map, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp scrub_known_secrets(text, secrets) when is_list(secrets) do
    Enum.reduce(secrets, text, fn
      secret, acc when is_binary(secret) and byte_size(secret) >= 4 ->
        String.replace(acc, secret, @redacted_placeholder)

      _other, acc ->
        acc
    end)
  end

  defp scrub_known_secrets(text, _), do: text

  defp scrub_bearer_tokens(text) do
    Regex.replace(~r/(Bearer\s+)[a-zA-Z0-9._\-]{20,}/i, text, "\\1#{@redacted_placeholder}")
  end

  defp scrub_env_assignments(text) do
    text
    |> then(
      &Regex.replace(
        ~r/([A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASS|CREDENTIAL|DATABASE_URL|URL|URI)=)[^\s\r\n]+/i,
        &1,
        "\\1#{@redacted_placeholder}"
      )
    )
    |> then(
      &Regex.replace(
        ~r/(:\/\/[^:\s\/]+:)[^@\s\/]+(@)/,
        &1,
        "\\1#{@redacted_placeholder}\\2"
      )
    )
  end

  defp scrub_regex_patterns(text) do
    Enum.reduce(secret_patterns(), text, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted_placeholder)
    end)
  end

  defp sensitive_key?(key) when is_binary(key) do
    upper = String.upcase(key)
    Enum.any?(@sensitive_env_keys, &String.contains?(upper, &1))
  end

  defp sensitive_key?(_), do: false

  defp stringify_env_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), to_string(v))
    end)
  end

  defp stringify_env_map(_), do: %{}
end
