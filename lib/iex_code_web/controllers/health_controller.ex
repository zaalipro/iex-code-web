defmodule IexCodeWeb.HealthController do
  @moduledoc "Minimal liveness and readiness probes for self-hosted deployments."

  use IexCodeWeb, :controller

  alias IexCode.Repo

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: json(conn, %{status: "ok"})

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    case readiness() do
      :ok ->
        json(conn, %{status: "ready"})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable"})
    end
  end

  defp readiness do
    with {:ok, _result} <- database_ready?(),
         :ok <- optional_supervisor_ready?(IexCode.Runs.RunDispatcher, :start_run_dispatcher),
         :ok <- supervisor_ready?(IexCode.Tools.TerminalSupervisor),
         :ok <- writable_parent?(Repo.config()[:database]) do
      :ok
    end
  rescue
    _error -> {:error, :readiness_check_failed}
  catch
    :exit, _reason -> {:error, :readiness_check_failed}
  end

  defp database_ready?, do: Repo.query("SELECT 1", [], timeout: 1_000)

  defp supervisor_ready?(name) do
    if Process.whereis(name), do: :ok, else: {:error, :supervisor_unavailable}
  end

  defp optional_supervisor_ready?(name, config_key) do
    if Application.get_env(:iex_code, config_key, true),
      do: supervisor_ready?(name),
      else: :ok
  end

  defp writable_parent?(path) when is_binary(path) and path not in ["", ":memory:"] do
    parent = Path.dirname(path)

    case File.stat(parent) do
      {:ok, %{type: :directory, access: access}} when access in [:write, :read_write] -> :ok
      _other -> {:error, :data_directory_unwritable}
    end
  end

  defp writable_parent?(_path), do: :ok
end
