defmodule IexCode.Engine.CoderTranscriptTest do
  use IexCode.DataCase, async: false

  alias IexCode.{CoderAgentLoopLLMStub, Projects, Sessions}
  alias IexCode.Engine.Agents.CoderAgent

  for text <- [nil, "", "Inspecting the project"] do
    @text text
    test "preserves tool requests and matching replies when model text is #{inspect(text)}" do
      {:ok, project} = Projects.create_project(%{name: "Transcript", root_path: File.cwd!()})
      {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Transcript"})

      calls = [
        %{id: "read-first", name: "read_file", args: %{"path" => "first.ex"}},
        %{id: "read-second", name: "read_file", args: %{"path" => "second.ex"}}
      ]

      start_supervised!(
        {CoderAgentLoopLLMStub,
         [
           {:ok, %{text: @text, tool_calls: calls}},
           {:ok, %{text: "Reviewed the tool results", tool_calls: []}}
         ]}
      )

      coder =
        start_supervised!(
          {CoderAgent,
           session_id: session.id, project_root: project.root_path, llm: CoderAgentLoopLLMStub}
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), coder)

      assert {:ok, "Reviewed the tool results"} =
               CoderAgent.code(coder, "Inspect both files", allowed_tools: [])

      assert [_initial, [_objective, assistant, first_result, second_result]] =
               CoderAgentLoopLLMStub.requests()

      assert assistant == %{role: "assistant", content: @text || "", tool_calls: calls}
      assert %{role: "tool", tool_call_id: "read-first"} = first_result
      assert %{role: "tool", tool_call_id: "read-second"} = second_result
    end
  end
end
