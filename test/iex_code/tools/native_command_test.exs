defmodule IexCode.Tools.NativeCommandTest do
  use IexCode.DataCase, async: false

  alias IexCode.Outputs
  alias IexCode.Tools.NativeCommand

  @tag :tmp_dir
  test "spools full output, enforces its ceiling, and terminates the producer process group", %{
    tmp_dir: root
  } do
    output_root = Path.join(root, "outputs")

    opts = [
      output_artifact: true,
      output_limit_bytes: 4 * 1_024,
      output_options: [
        root: output_root,
        min_free_bytes: 1,
        free_bytes: fn _root -> 1_073_741_824 end,
        global_quota_bytes: 64 * 1_024,
        preview_bytes: 128
      ]
    ]

    assert {:error, {:output_limit_exceeded, artifact_id}} =
             NativeCommand.run("echo $$; exec yes NATIVE_LIMIT", root, opts)

    artifact = Outputs.get(artifact_id)
    assert artifact.status == "limit_exceeded"
    assert artifact.byte_size == 4 * 1_024
    assert byte_size(artifact.preview_head) <= 128
    assert byte_size(artifact.preview_tail) <= 128

    assert {:ok, captured} = Outputs.read_chunk(artifact, 0, 64 * 1_024, root: output_root)
    assert byte_size(captured) == 4 * 1_024
    [pid_line | _rest] = String.split(captured, "\n", trim: true)
    {producer_pid, ""} = Integer.parse(String.trim(pid_line))

    assert {_, status} =
             System.cmd("kill", ["-0", Integer.to_string(producer_pid)], stderr_to_stdout: true)

    assert status != 0
  end

  @tag :tmp_dir
  test "returns a bounded preview and safely retrieves large successful output", %{tmp_dir: root} do
    output_root = Path.join(root, "outputs")

    assert {:ok, result} =
             NativeCommand.run("yes 123456789 | head -c 2048", root,
               output_artifact: true,
               output_options: [
                 root: output_root,
                 limit_bytes: 8 * 1_024,
                 preview_bytes: 64,
                 min_free_bytes: 1,
                 free_bytes: fn _root -> 1_073_741_824 end,
                 global_quota_bytes: 64 * 1_024
               ]
             )

    assert result.exit_code == 0
    assert result.output_bytes >= 2_048
    assert result.output_truncated?
    assert byte_size(result.output) < result.output_bytes
    assert result.output =~ "retrieve artifact"

    artifact = Outputs.get(result.artifact_id)
    assert {:ok, chunk} = Outputs.read_chunk(artifact, 0, 1_024, root: output_root)

    assert byte_size(chunk) == 1_024
  end
end
