defmodule IexCode.Tools.OutputArtifactToolTest do
  use IexCode.DataCase, async: false

  alias IexCode.Outputs
  alias IexCode.Tools

  @tag :tmp_dir
  test "reads bounded sanitized chunks only through a trusted matching scope", %{tmp_dir: root} do
    output_root = Path.join(root, "outputs")
    project = project!(root)
    session = session!(project.id, "artifact owner")
    other_session = session!(project.id, "other session")

    {:ok, operation} =
      IexCode.Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "run_command",
        title: "artifact producer"
      })

    {:ok, writer} =
      Outputs.open_writer(
        %{
          session_id: session.id,
          operation_id: operation.id,
          kind: "terminal_command_output",
          name: "command.log"
        },
        root: output_root,
        limit_bytes: 128,
        min_free_bytes: 1,
        free_bytes: fn _root -> 1_073_741_824 end,
        global_quota_bytes: 1_024
      )

    assert {:ok, writer} = Outputs.append(writer, <<"hello", 255, " world">>)
    assert {:ok, artifact} = Outputs.finish(writer)

    args = %{
      "artifact_id" => artifact.id,
      "offset" => 0,
      "length" => 8,
      "project_id" => project.id,
      "session_id" => session.id,
      "op_id" => operation.id
    }

    previous_root = Application.get_env(:iex_code, :output_artifact_root)
    Application.put_env(:iex_code, :output_artifact_root, output_root)

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:iex_code, :output_artifact_root, previous_root),
        else: Application.delete_env(:iex_code, :output_artifact_root)
    end)

    assert {:ok, output} = Tools.execute("read_output_artifact", args, root)
    assert String.valid?(output)
    assert output =~ "Artifact: #{artifact.id}"
    assert output =~ "Next offset: 8"
    assert output =~ "EOF: false"
    refute output =~ artifact.relative_path
    refute output =~ output_root

    assert {:error, unavailable} =
             Tools.execute(
               "read_output_artifact",
               %{args | "session_id" => other_session.id},
               root
             )

    assert unavailable =~ "unavailable"

    assert {:error, range_error} =
             Tools.execute(
               "read_output_artifact",
               %{args | "length" => 65_537},
               root
             )

    assert range_error =~ "1..65536"
  end

  @tag :tmp_dir
  test "tool manifest exposes only opaque artifact and bounded range parameters", %{
    tmp_dir: _root
  } do
    definition = Enum.find(Tools.tool_definitions(), &(&1.name == "read_output_artifact"))
    assert definition
    assert definition.parameters.required == ["artifact_id"]
    assert definition.parameters.properties.length.maximum == 65_536
    refute Map.has_key?(definition.parameters.properties, :path)
    refute Map.has_key?(definition.parameters.properties, :session_id)
  end

  @tag :tmp_dir
  test "test and terminal tools persist their validated session and operation scope", %{
    tmp_dir: root
  } do
    output_root = Path.join(root, "outputs")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(workspace, "test"))

    File.write!(
      Path.join(workspace, "mix.exs"),
      """
      defmodule ArtifactScope.MixProject do
        use Mix.Project
        def project, do: [app: :artifact_scope, version: "0.1.0", elixir: "~> 1.15"]
        def application, do: []
      end
      """
    )

    File.write!(Path.join(workspace, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(workspace, "test/scope_test.exs"),
      "defmodule ScopeTest do\n  use ExUnit.Case\n  test(\"ok\", do: assert(true))\nend\n"
    )

    project = project!(workspace)
    session = session!(project.id, "producer scope")
    test_operation = operation!(session.id, "run_tests")
    terminal_operation = operation!(session.id, "run_command")

    previous_root = Application.get_env(:iex_code, :output_artifact_root)
    previous_output_config = Application.get_env(:iex_code, :output_artifacts)
    Application.put_env(:iex_code, :output_artifact_root, output_root)
    Application.put_env(:iex_code, :output_artifacts, enabled: true)

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:iex_code, :output_artifact_root, previous_root),
        else: Application.delete_env(:iex_code, :output_artifact_root)

      if previous_output_config,
        do: Application.put_env(:iex_code, :output_artifacts, previous_output_config),
        else: Application.delete_env(:iex_code, :output_artifacts)
    end)

    assert {:ok, test_output} =
             Tools.execute(
               "run_tests",
               %{
                 "project_id" => project.id,
                 "session_id" => session.id,
                 "op_id" => test_operation.id,
                 "paths" => ["test/scope_test.exs"]
               },
               workspace
             )

    [test_artifact_id] =
      Regex.run(~r/Output artifact: ([0-9a-f-]+)/, test_output, capture: :all_but_first)

    test_artifact = Outputs.get(test_artifact_id)
    assert test_artifact.session_id == session.id
    assert test_artifact.operation_id == test_operation.id

    assert {:ok, terminal_output} =
             Tools.execute(
               "run_command",
               %{
                 "command" => "printf TERMINAL_SCOPE",
                 "project_id" => project.id,
                 "session_id" => session.id,
                 "op_id" => terminal_operation.id,
                 "agent_name" => "ScopeAgent"
               },
               workspace
             )

    assert terminal_output =~ "TERMINAL_SCOPE"

    terminal_artifact =
      Repo.one!(
        from artifact in IexCode.Outputs.OutputArtifact,
          where: artifact.kind == "terminal_command_output",
          order_by: [desc: artifact.inserted_at, desc: artifact.id],
          limit: 1
      )

    assert terminal_artifact.session_id == session.id
    assert terminal_artifact.operation_id == terminal_operation.id
  end

  defp project!(root) do
    %IexCode.Projects.Project{}
    |> IexCode.Projects.Project.changeset(%{name: "artifact-tool", root_path: root})
    |> Repo.insert!()
  end

  defp session!(project_id, title) do
    {:ok, session} = IexCode.Sessions.create_session(%{project_id: project_id, title: title})
    session
  end

  defp operation!(session_id, op_type) do
    {:ok, operation} =
      IexCode.Sessions.create_operation(%{
        session_id: session_id,
        agent_name: "ScopeAgent",
        op_type: op_type,
        title: "scope producer"
      })

    operation
  end
end
