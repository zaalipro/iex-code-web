defmodule IexCode.Execution.CommandParser do
  @moduledoc """
  Strict, side-effect-free parsing for composer and CLI execution commands.

  Only the exact, lowercase first token selects a command.  Prefixes such as
  `/researcher` and mixed-case tokens such as `/Goal` are never interpreted as
  supported commands.
  """

  alias IexCode.Execution.{CommandError, Intent}

  @max_input_bytes 100_000
  @max_attachment_id 9_223_372_036_854_775_807
  @levels ~w(low medium high ultra)
  @command_help [
    %{
      command: "/chat",
      usage: "/chat <objective>",
      summary: "Force an interactive single-agent prompt."
    },
    %{
      command: "/ask",
      usage: "/ask <objective>",
      summary: "Alias for /chat."
    },
    %{
      command: "/run",
      usage: "/run <objective>",
      summary: "Queue a durable single-agent run."
    },
    %{
      command: "/swarm",
      usage: "/swarm <objective>",
      summary: "Queue a durable multi-agent coding swarm."
    },
    %{
      command: "/goal",
      usage: "/goal [--draft] <objective>",
      summary:
        "Create a durable goal; --draft saves it without starting. In the composer, /goal alone opens the reviewed goal form."
    },
    %{
      command: "/research",
      usage: "/research [--level low|medium|high|ultra] <objective>",
      summary:
        "Queue an exact, bounded durable research workflow. In the composer, /research alone opens Research."
    },
    %{
      command: "/deep_research",
      usage: "/deep_research [result_number]",
      summary: "In the composer, open the ready-result picker or attach one verified result."
    },
    %{
      command: "/kanban",
      usage: "/kanban",
      summary: "In the composer, open the Kanban workspace."
    },
    %{
      command: "/help",
      usage: "/help",
      summary: "Show command usage and execution semantics."
    }
  ]
  @supported_commands Enum.map(@command_help, & &1.command)

  @type parse_result :: {:ok, Intent.t()} | {:error, CommandError.t()}

  @spec parse(term(), keyword()) :: parse_result()
  def parse(input, opts \\ [])

  def parse(input, opts) when is_binary(input) and is_list(opts) do
    source = normalize_source(Keyword.get(opts, :source, "composer"))

    cond do
      byte_size(input) > @max_input_bytes ->
        error(:input_too_large, "Input exceeds the 100 KB execution boundary")

      not String.valid?(input) ->
        error(:invalid_encoding, "Input must be valid UTF-8")

      true ->
        input
        |> String.trim()
        |> parse_trimmed(source)
    end
  end

  def parse(_input, _opts),
    do: error(:invalid_input, "Execution input must be a UTF-8 string")

  @spec supported_commands() :: [String.t()]
  def supported_commands, do: @supported_commands

  @doc "Returns the ordered command catalog used by composer and CLI help."
  @spec command_help() :: [%{command: String.t(), usage: String.t(), summary: String.t()}]
  def command_help, do: @command_help

  @doc "Renders concise help with exact grammar and durability semantics."
  @spec help_text() :: String.t()
  def help_text do
    introduction =
      "Ordinary text follows the selected Interactive or Background dispatch mode. " <>
        "Slash commands are lowercase and exact:"

    lines = Enum.map_join(@command_help, "\n", &"  #{&1.usage} — #{&1.summary}")
    introduction <> "\n" <> lines
  end

  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: @max_input_bytes

  defp parse_trimmed("", _source), do: error(:empty_input, "Enter a prompt or command")

  defp parse_trimmed("/" = command, _source),
    do: unknown_command(command)

  defp parse_trimmed("/" <> _rest = input, source) do
    {command, arguments} = split_command(input)
    parse_command(command, arguments, source)
  end

  defp parse_trimmed(objective, source) do
    {:ok, intent(:prompt, objective, :interactive, :single, source, raw_command: nil)}
  end

  defp parse_command(command, arguments, source) when command in ["/chat", "/ask"] do
    with {:ok, objective} <- required_objective(command, arguments) do
      {:ok, intent(:prompt, objective, :interactive, :single, source, raw_command: command)}
    end
  end

  defp parse_command("/run" = command, arguments, source) do
    with {:ok, objective} <- required_objective(command, arguments) do
      {:ok, intent(:run, objective, :durable, :single, source, raw_command: command)}
    end
  end

  defp parse_command("/swarm" = command, arguments, source) do
    with {:ok, objective} <- required_objective(command, arguments) do
      {:ok, intent(:swarm, objective, :durable, :swarm, source, raw_command: command)}
    end
  end

  defp parse_command("/goal" = command, arguments, source) do
    case split_option(arguments) do
      {"--draft", rest} ->
        with {:ok, objective} <- required_objective(command, rest) do
          {:ok,
           intent(:goal, objective, :durable, :swarm, source,
             raw_command: command,
             draft?: true
           )}
        end

      {"--" <> _option = option, _rest} ->
        error(:invalid_option, "Unsupported option #{option} for /goal", command)

      _no_option ->
        with {:ok, objective} <- required_objective(command, arguments) do
          {:ok, intent(:goal, objective, :durable, :swarm, source, raw_command: command)}
        end
    end
  end

  defp parse_command("/research" = command, arguments, source) do
    case split_option(arguments) do
      {"--level", rest} ->
        parse_research_level(command, rest, source)

      {"--" <> _option = option, _rest} ->
        error(:invalid_option, "Unsupported option #{option} for /research", command)

      _no_option ->
        with {:ok, objective} <- required_objective(command, arguments) do
          {:ok, intent(:research, objective, :durable, :research, source, raw_command: command)}
        end
    end
  end

  defp parse_command("/deep_research" = command, "", source) do
    {:ok, intent(:research_picker, nil, :none, :research, source, raw_command: command)}
  end

  defp parse_command("/deep_research" = command, arguments, source) do
    with {:ok, attachment_id} <- parse_attachment_id(arguments, command) do
      {:ok,
       intent(:research_attachment, nil, :none, :research, source,
         raw_command: command,
         attachment_id: attachment_id
       )}
    end
  end

  defp parse_command("/kanban" = command, "", source) do
    {:ok, intent(:navigate, "kanban", :none, :navigation, source, raw_command: command)}
  end

  defp parse_command("/kanban" = command, _arguments, _source),
    do: error(:unexpected_arguments, "/kanban does not accept arguments", command)

  defp parse_command("/help" = command, "", source) do
    {:ok, intent(:help, nil, :none, :help, source, raw_command: command)}
  end

  defp parse_command("/help" = command, _arguments, _source),
    do: error(:unexpected_arguments, "/help does not accept arguments", command)

  defp parse_command(command, _arguments, _source), do: unknown_command(command)

  defp parse_research_level(command, rest, source) do
    {level, objective} = split_command(rest)

    cond do
      level == "" ->
        error(:invalid_level, "Provide a research level: low, medium, high, or ultra", command)

      level not in @levels ->
        error(
          :invalid_level,
          "Invalid research level #{inspect(level)}; use low, medium, high, or ultra",
          command
        )

      true ->
        with {:ok, objective} <- required_objective(command, objective) do
          {:ok,
           intent(:research, objective, :durable, :research, source,
             raw_command: command,
             level: level
           )}
        end
    end
  end

  defp parse_attachment_id(arguments, command) do
    candidate = String.trim(arguments)

    cond do
      not Regex.match?(~r/^[1-9][0-9]*$/, candidate) ->
        error(
          :invalid_attachment_id,
          "Use /deep_research with one positive result number",
          command
        )

      byte_size(candidate) > 19 ->
        error(
          :invalid_attachment_id,
          "Research result number is outside the supported range",
          command
        )

      true ->
        case Integer.parse(candidate) do
          {id, ""} when id <= @max_attachment_id ->
            {:ok, id}

          _ ->
            error(
              :invalid_attachment_id,
              "Research result number is outside the supported range",
              command
            )
        end
    end
  end

  defp required_objective(command, arguments) do
    objective = String.trim(arguments)

    cond do
      objective == "" ->
        error(
          :missing_objective,
          "#{command} requires an objective. Usage: #{command_usage(command)}",
          command
        )

      byte_size(objective) > @max_input_bytes ->
        error(:input_too_large, "Objective exceeds the 100 KB execution boundary", command)

      true ->
        {:ok, objective}
    end
  end

  defp split_command(input) do
    case Regex.run(~r/^([^\s]+)(?:\s+(.*))?$/s, input) do
      [_all, token, rest] -> {token, String.trim(rest)}
      [_all, token] -> {token, ""}
      _ -> {"", ""}
    end
  end

  defp split_option(arguments) do
    case split_command(arguments) do
      {"--" <> _rest = option, remaining} -> {option, remaining}
      _ -> :none
    end
  end

  defp intent(kind, objective, durability, mode, source, opts) do
    %Intent{
      kind: kind,
      objective: objective,
      durability: durability,
      mode: mode,
      draft?: Keyword.get(opts, :draft?, false),
      level: Keyword.get(opts, :level),
      attachment_id: Keyword.get(opts, :attachment_id),
      raw_command: Keyword.get(opts, :raw_command),
      source: source
    }
  end

  defp unknown_command(command) do
    error(
      :unknown_command,
      "Unknown command #{inspect(command)}. Commands are lowercase and exact. " <>
        "Supported commands: #{Enum.join(@supported_commands, ", ")}. Use /help for usage.",
      command
    )
  end

  defp command_usage(command) do
    case Enum.find(@command_help, &(&1.command == command)) do
      %{usage: usage} -> usage
      nil -> command
    end
  end

  defp error(code, message, command \\ nil) do
    {:error,
     %CommandError{
       code: code,
       message: message,
       command: command,
       supported_commands: @supported_commands
     }}
  end

  defp normalize_source(source) when is_atom(source), do: Atom.to_string(source)

  defp normalize_source(source) when is_binary(source) do
    if String.valid?(source) do
      source
      |> String.trim()
      |> case do
        "" -> "composer"
        value -> String.slice(value, 0, 100)
      end
    else
      "composer"
    end
  end

  defp normalize_source(_source), do: "composer"
end
