defmodule Mix.Tasks.IexCode.Runs do
  @moduledoc """
  Lists a bounded set of recent local runs.

      mix iex_code.runs [--project PATH|ID] [--session ID] [--limit N] [--json]

  The default limit is 20 and the maximum is 100. Output never includes run
  metadata, policy internals, credentials, or provider endpoints.
  """

  use Mix.Task

  alias IexCode.{CLI, Runs, Sessions}

  @shortdoc "Lists bounded recent local IexCode runs"

  @switches [project: :string, session: :string, limit: :integer, json: :boolean]
  @aliases [p: :project, s: :session, j: :json, l: :limit]

  @impl Mix.Task
  def run(argv) do
    CLI.start_app()

    with {opts, [], []} <- OptionParser.parse(argv, strict: @switches, aliases: @aliases),
         {:ok, limit} <- bounded_limit(opts[:limit]),
         {:ok, filters} <- filters(opts) do
      runs = Runs.list_runs(Keyword.put(filters, :limit, limit))
      print_runs(runs, opts[:json])
    else
      {_opts, args, invalid} ->
        details = if invalid == [], do: Enum.join(args, " "), else: inspect(invalid)
        Mix.raise("invalid iex_code.runs arguments: #{details}")

      {:error, reason} ->
        Mix.raise(CLI.format_error(reason))
    end
  end

  defp filters(opts) do
    with {:ok, session} <- optional_session(opts[:session]),
         {:ok, project} <- optional_project(opts[:project]),
         :ok <- matching_scope(session, project) do
      filters = []
      filters = if session, do: Keyword.put(filters, :session_id, session.id), else: filters
      filters = if project, do: Keyword.put(filters, :project_id, project.id), else: filters
      {:ok, filters}
    end
  end

  defp optional_session(nil), do: {:ok, nil}

  defp optional_session(id) do
    case Sessions.get_session(id) do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  rescue
    _error -> {:error, :session_not_found}
  end

  defp optional_project(nil), do: {:ok, nil}
  defp optional_project(reference), do: CLI.resolve_project(reference, create?: false)

  defp matching_scope(nil, _project), do: :ok
  defp matching_scope(_session, nil), do: :ok

  defp matching_scope(session, project) do
    if session.project_id == project.id, do: :ok, else: {:error, :session_project_mismatch}
  end

  defp bounded_limit(nil), do: {:ok, 20}
  defp bounded_limit(limit) when is_integer(limit) and limit in 1..100, do: {:ok, limit}
  defp bounded_limit(_limit), do: {:error, :invalid_limit}

  defp print_runs(runs, true),
    do: Mix.shell().info(Jason.encode!(Enum.map(runs, &CLI.run_json/1)))

  defp print_runs([], _json?), do: Mix.shell().info("No runs found.")

  defp print_runs(runs, _json?) do
    Enum.each(runs, fn run ->
      Mix.shell().info(
        "#{run.id}  #{String.pad_trailing(run.status, 11)}  #{run.kind}/#{run.mode}  #{truncate(run.objective, 70)}"
      )
    end)
  end

  defp truncate(value, maximum) do
    if String.length(value) <= maximum,
      do: value,
      else: String.slice(value, 0, maximum - 1) <> "…"
  end
end
