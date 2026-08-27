defmodule IexCode.OutputsTest do
  use IexCode.DataCase, async: false

  alias IexCode.Outputs

  @moduletag :tmp_dir
  @ample_disk 20 * 1_073_741_824

  test "spools complete output while retaining bounded head and tail previews", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 128, preview_bytes: 8)
    assert {:ok, writer} = Outputs.append(writer, "abcdefgh")
    assert {:ok, writer} = Outputs.append(writer, "ijklmnop")
    assert {:ok, artifact} = Outputs.finish(writer)

    assert artifact.status == "ready"
    assert artifact.byte_size == 16
    assert artifact.reserved_bytes == 0
    assert artifact.preview_head == "abcdefgh"
    assert artifact.preview_tail == "ijklmnop"
    assert artifact.checksum == sha256("abcdefghijklmnop")
    assert {:ok, "efghij"} = Outputs.read_chunk(artifact, 4, 6, root: root)

    assert {:error, :scope_required} = Outputs.fetch(artifact.id)
  end

  test "stops exactly at the per-artifact ceiling and preserves the captured artifact", %{
    tmp_dir: root
  } do
    {:ok, writer} = open_writer(root, limit_bytes: 10, preview_bytes: 4)
    assert {:limit_exceeded, writer} = Outputs.append(writer, "0123456789discarded")
    assert {:ok, artifact} = Outputs.finish(writer, :limit_exceeded)

    assert artifact.status == "limit_exceeded"
    assert artifact.byte_size == 10
    assert artifact.preview_head == "0123"
    assert artifact.preview_tail == "6789"
    assert {:ok, "0123456789"} = Outputs.read_chunk(artifact, 0, 64 * 1_024, root: root)
  end

  test "durable reservations prevent concurrent quota overcommit", %{tmp_dir: root} do
    {:ok, first} =
      open_writer(root,
        limit_bytes: 8,
        global_quota_bytes: 12,
        preview_bytes: 4
      )

    assert {:error, :output_quota_exceeded} =
             open_writer(root,
               limit_bytes: 8,
               global_quota_bytes: 12,
               preview_bytes: 4
             )

    assert :ok = Outputs.discard(first)

    assert {:ok, second} =
             open_writer(root,
               limit_bytes: 8,
               global_quota_bytes: 12,
               preview_bytes: 4
             )

    assert :ok = Outputs.discard(second)
  end

  test "simultaneous reservations are serialized at the quota boundary", %{tmp_dir: root} do
    parent = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(parent, {:reservation_ready, self()})

          receive do
            :reserve ->
              open_writer(root,
                limit_bytes: 8,
                global_quota_bytes: 8,
                preview_bytes: 4
              )
          end
        end)
      end

    pids =
      for _index <- 1..2 do
        assert_receive {:reservation_ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :reserve))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [{:ok, writer}] = Enum.filter(results, &match?({:ok, _writer}, &1))
    assert [{:error, :output_quota_exceeded}] = Enum.reject(results, &match?({:ok, _}, &1))
    assert :ok = Outputs.discard(writer)
  end

  test "fails closed when the filesystem safety floor is unavailable", %{tmp_dir: root} do
    assert {:error, :insufficient_disk_space} =
             Outputs.open_writer(%{kind: "test", name: "output.log"},
               root: root,
               limit_bytes: 8,
               min_free_bytes: 10,
               free_bytes: fn _root -> 9 end
             )

    assert {:error, :disk_space_unavailable} =
             Outputs.open_writer(%{kind: "test", name: "output.log"},
               root: root,
               limit_bytes: 8,
               min_free_bytes: 10,
               free_bytes: fn _root -> nil end
             )
  end

  test "file preparation failure releases the durable reservation", %{tmp_dir: root} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    File.write!(Path.join(root, Integer.to_string(now.year)), "not-a-directory")

    assert {:error, :enotdir} =
             open_writer(root,
               now: now,
               limit_bytes: 8,
               preview_bytes: 4
             )

    assert Repo.aggregate(IexCode.Outputs.OutputArtifact, :count) == 0
  end

  test "discard removes both the partial file and reservation", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 4)
    assert {:ok, writer} = Outputs.append(writer, "temporary")
    assert File.exists?(writer.partial_path)

    assert :ok = Outputs.discard(writer)
    refute File.exists?(writer.partial_path)
    assert Outputs.get(writer.artifact_id) == nil
  end

  test "finish failure removes the renamed file and releases its reservation", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 4)
    assert {:ok, writer} = Outputs.append(writer, "temporary")

    oversized_metadata = %{"value" => String.duplicate("x", 65_000)}
    assert {:error, %Ecto.Changeset{}} = Outputs.finish(writer, :ready, oversized_metadata)

    refute File.exists?(writer.partial_path)
    refute File.exists?(writer.final_path)
    assert Outputs.get(writer.artifact_id) == nil

    assert {:ok, replacement} = open_writer(root, limit_bytes: 64, preview_bytes: 4)
    assert :ok = Outputs.discard(replacement)
  end

  test "discard refuses tampered writer paths", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 4)

    outside =
      Path.join(Path.dirname(root), "must-not-delete-#{System.unique_integer([:positive])}")

    File.write!(outside, "safe")

    tampered = %{writer | partial_path: outside, final_path: outside}
    assert :ok = Outputs.discard(tampered)
    assert File.read!(outside) == "safe"
    assert Outputs.get(writer.artifact_id).status == "writing"

    assert :ok = Outputs.discard(writer)
    assert Outputs.get(writer.artifact_id) == nil
  end

  test "chunk retrieval rejects traversal paths and unpublished writers", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 4)
    assert {:error, :scope_required} = Outputs.fetch(writer.artifact_id)

    assert {:ok, artifact} = Outputs.finish(writer)
    malicious = %{artifact | relative_path: "../outside.log"}
    assert {:error, :invalid_artifact_path} = Outputs.read_chunk(malicious, 0, 8, root: root)
  end

  test "retention cleanup never follows a database path outside its root", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 4)
    assert {:ok, writer} = Outputs.append(writer, "safe")
    assert {:ok, artifact} = Outputs.finish(writer)

    outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}.log")
    File.write!(outside, "must survive")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(a in IexCode.Outputs.OutputArtifact, where: a.id == ^artifact.id)
    |> Repo.update_all(
      set: [relative_path: "../#{Path.basename(outside)}", expires_at: DateTime.add(now, -1)]
    )

    assert {:error, {:artifact_file_cleanup_incomplete, 0, 1}} =
             Outputs.cleanup_expired(root: root, now: now)

    assert File.read!(outside) == "must survive"
    assert Outputs.get(artifact.id).status == "deleting"
  end

  test "published artifacts cannot be finished twice or discarded through a stale writer", %{
    tmp_dir: root
  } do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 4)
    assert {:ok, writer} = Outputs.append(writer, "durable")
    assert {:ok, artifact} = Outputs.finish(writer)
    assert {:error, :writer_closed} = Outputs.finish(writer)
    assert :ok = Outputs.discard(writer)
    assert Outputs.get(artifact.id) == artifact
  end

  test "scoped retrieval hides paths and rejects unpublished, expired, and mismatched artifacts",
       %{
         tmp_dir: root
       } do
    {session, operation, other_session} = scoped_records(root)

    {:ok, writer} =
      open_writer(root,
        attrs: %{session_id: session.id, operation_id: operation.id},
        limit_bytes: 64,
        preview_bytes: 8
      )

    assert {:ok, writer} = Outputs.append(writer, "scope-safe-output")
    assert {:error, :not_found} = Outputs.fetch(writer.artifact_id, session_id: session.id)
    assert {:ok, artifact} = Outputs.finish(writer)

    assert {:ok, metadata} = Outputs.fetch(artifact.id, session_id: session.id)
    assert metadata.id == artifact.id
    refute Map.has_key?(metadata, :relative_path)
    refute Map.has_key?(metadata, :session_id)

    assert {:ok, %{data: "safe", next_offset: 10, eof: false, artifact: chunk_metadata}} =
             Outputs.fetch_chunk(artifact.id, %{operation_id: operation.id}, 6, 4, root: root)

    refute Map.has_key?(chunk_metadata, :relative_path)

    assert {:error, :not_found} =
             Outputs.fetch_chunk(artifact.id, %{session_id: other_session.id}, 0, 4, root: root)

    assert {:error, :not_found} =
             Outputs.fetch(artifact.id,
               session_id: session.id,
               operation_id: Ecto.UUID.generate()
             )

    assert {:error, :invalid_range} =
             Outputs.fetch_chunk(artifact.id, %{session_id: session.id}, 0, 65_537, root: root)

    assert {:error, :invalid_scope} =
             Outputs.fetch(artifact.id, %{session_id: session.id, run_id: 123})

    expired_at = DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -1, :second)

    artifact
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    assert {:error, :not_found} = Outputs.fetch(artifact.id, session_id: session.id)
  end

  test "expired artifacts stay scoped and retrievable for active runs until completion", %{
    tmp_dir: root
  } do
    {session, operation, other_session} = scoped_records(root)

    {:ok, run} =
      IexCode.Runs.create_run(%{
        project_id: session.project_id,
        session_id: session.id,
        objective: "Keep active run output available"
      })

    {:ok, writer} =
      open_writer(root,
        attrs: %{
          run_id: run.id,
          session_id: session.id,
          operation_id: operation.id
        },
        limit_bytes: 64,
        preview_bytes: 8
      )

    assert {:ok, writer} = Outputs.append(writer, "active-run-output")
    assert {:ok, artifact} = Outputs.finish(writer)
    final_path = Path.join(root, artifact.relative_path)

    artifact
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -60, :second)
    )
    |> Repo.update!()

    exact_scope = %{
      session_id: session.id,
      run_id: run.id,
      operation_id: operation.id
    }

    for status <- ~w(queued running paused) do
      run = IexCode.Runs.get_run!(run.id)

      if run.status != status do
        assert {:ok, %{status: ^status}} = IexCode.Runs.transition_run(run, status)
      end

      # Reserving another artifact runs retention cleanup. Active run output must
      # survive cleanup as well as the read-time expiration check.
      assert {:ok, cleanup_trigger} =
               open_writer(root, limit_bytes: 32, preview_bytes: 4)

      assert :ok = Outputs.discard(cleanup_trigger)
      assert File.exists?(final_path)
      assert Outputs.get(artifact.id)

      assert {:ok, %{id: id}} = Outputs.fetch(artifact.id, exact_scope)
      assert id == artifact.id

      assert {:ok, %{data: "active", next_offset: 6, eof: false}} =
               Outputs.fetch_chunk(artifact.id, exact_scope, 0, 6, root: root)
    end

    assert {:error, :not_found} =
             Outputs.fetch(artifact.id, %{exact_scope | session_id: other_session.id})

    assert {:error, :not_found} =
             Outputs.fetch(artifact.id, %{exact_scope | run_id: Ecto.UUID.generate()})

    assert {:error, :not_found} =
             Outputs.fetch_chunk(
               artifact.id,
               %{exact_scope | operation_id: Ecto.UUID.generate()},
               0,
               6,
               root: root
             )

    assert {:ok, completed} = IexCode.Runs.transition_run(run.id, "completed")
    assert completed.status == "completed"
    assert {:error, :not_found} = Outputs.fetch(artifact.id, exact_scope)
    assert {:error, :not_found} = Outputs.fetch_chunk(artifact.id, exact_scope, 0, 6, root: root)

    assert {:ok, cleanup_trigger} = open_writer(root, limit_bytes: 32, preview_bytes: 4)
    assert :ok = Outputs.discard(cleanup_trigger)
    assert Outputs.get(artifact.id) == nil
    refute File.exists?(final_path)
  end

  test "expired files are not deleted when artifact reservation transaction rolls back", %{
    tmp_dir: root
  } do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 8)
    assert {:ok, writer} = Outputs.append(writer, "must-survive-rollback")
    assert {:ok, artifact} = Outputs.finish(writer)
    final_path = Path.join(root, artifact.relative_path)
    assert File.exists?(final_path)

    artifact
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -60, :second)
    )
    |> Repo.update!()

    assert {:error, %Ecto.Changeset{}} =
             Outputs.open_writer(%{kind: "", name: "invalid.log"},
               root: root,
               now: DateTime.utc_now() |> DateTime.truncate(:second),
               limit_bytes: 32,
               min_free_bytes: 1,
               free_bytes: fn _root -> @ample_disk end,
               global_quota_bytes: 1_024
             )

    assert Outputs.get(artifact.id)
    assert File.exists?(final_path)
  end

  test "explicit retention cleanup works without creating a future writer", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 8)
    assert {:ok, writer} = Outputs.append(writer, "expired")
    assert {:ok, artifact} = Outputs.finish(writer)
    final_path = Path.join(root, artifact.relative_path)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    artifact
    |> Ecto.Changeset.change(expires_at: DateTime.add(now, -1, :second))
    |> Repo.update!()

    assert {:ok, 1} = Outputs.cleanup_expired(root: root, now: now)
    assert Outputs.get(artifact.id) == nil
    refute File.exists?(final_path)
  end

  test "retention cleanup keeps retry metadata until file removal succeeds", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 8)
    assert {:ok, writer} = Outputs.append(writer, "retry cleanup")
    assert {:ok, artifact} = Outputs.finish(writer)
    final_path = Path.join(root, artifact.relative_path)
    artifact_directory = Path.dirname(final_path)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    artifact
    |> Ecto.Changeset.change(expires_at: DateTime.add(now, -1, :second))
    |> Repo.update!()

    File.chmod!(artifact_directory, 0o500)
    on_exit(fn -> File.chmod(artifact_directory, 0o700) end)

    assert {:error, {:artifact_file_cleanup_incomplete, 0, 1}} =
             Outputs.cleanup_expired(root: root, now: now)

    retained = Outputs.get(artifact.id)
    assert retained.status == "deleting"
    assert retained.byte_size == artifact.byte_size
    assert File.exists?(final_path)

    File.chmod!(artifact_directory, 0o700)
    assert {:ok, 1} = Outputs.cleanup_expired(root: root, now: now)
    assert Outputs.get(artifact.id) == nil
    refute File.exists?(final_path)
  end

  test "cleanup resumes a deleting row left by a prior process crash", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 8)
    assert {:ok, writer} = Outputs.append(writer, "resume cleanup")
    assert {:ok, artifact} = Outputs.finish(writer)
    final_path = Path.join(root, artifact.relative_path)

    artifact
    |> Ecto.Changeset.change(status: "deleting")
    |> Repo.update!()

    assert {:ok, 1} = Outputs.cleanup_expired(root: root)
    assert Outputs.get(artifact.id) == nil
    refute File.exists?(final_path)
  end

  test "a cleanup claim closes a stale producer that attempts to finish", %{tmp_dir: root} do
    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 8)
    assert {:ok, writer} = Outputs.append(writer, "stale producer")

    writer.artifact_id
    |> Outputs.get()
    |> Ecto.Changeset.change(status: "deleting")
    |> Repo.update!()

    assert {:error, :writer_closed} = Outputs.finish(writer)
    assert {:error, _reason} = :file.write(writer.io, "must not write")
    assert {:ok, 1} = Outputs.cleanup_expired(root: root)
    assert Outputs.get(writer.artifact_id) == nil
    refute File.exists?(writer.partial_path)
  end

  test "storage maintenance runs retention cleanup during its lifecycle", %{tmp_dir: root} do
    previous_config = Application.get_env(:iex_code, :output_artifacts)
    previous_root = Application.get_env(:iex_code, :output_artifact_root)

    Application.put_env(
      :iex_code,
      :output_artifacts,
      Keyword.put(previous_config || [], :enabled, true)
    )

    Application.put_env(:iex_code, :output_artifact_root, root)

    on_exit(fn ->
      restore_env(:output_artifacts, previous_config)
      restore_env(:output_artifact_root, previous_root)
    end)

    {:ok, writer} = open_writer(root, limit_bytes: 64, preview_bytes: 8)
    assert {:ok, writer} = Outputs.append(writer, "scheduled cleanup")
    assert {:ok, artifact} = Outputs.finish(writer)
    final_path = Path.join(root, artifact.relative_path)

    artifact
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -1, :second)
    )
    |> Repo.update!()

    maintenance_name = {:global, {:output_maintenance_test, make_ref()}}
    start_supervised!({IexCode.DatabasePermissions, name: maintenance_name})
    _ = :sys.get_state(maintenance_name)

    assert Outputs.get(artifact.id) == nil
    refute File.exists?(final_path)
  end

  test "session deletion preserves artifact rows until file retention cleanup", %{tmp_dir: root} do
    {session, operation, _other_session} = scoped_records(root)

    {:ok, writer} =
      open_writer(root,
        attrs: %{session_id: session.id, operation_id: operation.id},
        limit_bytes: 64,
        preview_bytes: 8
      )

    assert {:ok, writer} = Outputs.append(writer, "owner-deleted")
    assert {:ok, artifact} = Outputs.finish(writer)
    final_path = Path.join(root, artifact.relative_path)

    assert {:ok, _deleted} = IexCode.Sessions.delete_session(session)
    retained = Outputs.get(artifact.id)
    assert retained.session_id == nil
    assert retained.operation_id == nil
    assert File.exists?(final_path)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    retained
    |> Ecto.Changeset.change(expires_at: DateTime.add(now, -1, :second))
    |> Repo.update!()

    assert {:ok, 1} = Outputs.cleanup_expired(root: root, now: now)
    assert Outputs.get(artifact.id) == nil
    refute File.exists?(final_path)
  end

  test "configured limits are ceilings for per-call output overrides", %{tmp_dir: root} do
    previous = Application.get_env(:iex_code, :output_artifacts)

    Application.put_env(:iex_code, :output_artifacts,
      enabled: true,
      artifact_limit_bytes: 16,
      preview_bytes: 4,
      global_quota_bytes: 20,
      min_free_bytes: 1,
      retention_seconds: 60
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:iex_code, :output_artifacts, previous),
        else: Application.delete_env(:iex_code, :output_artifacts)
    end)

    assert {:ok, writer} =
             open_writer(root,
               limit_bytes: 1_024,
               preview_bytes: 1_024,
               global_quota_bytes: 1_024
             )

    assert writer.limit_bytes == 16
    assert writer.preview_bytes == 4

    assert {:error, :output_quota_exceeded} =
             open_writer(root,
               limit_bytes: 8,
               global_quota_bytes: 1_024
             )

    assert :ok = Outputs.discard(writer)
  end

  defp open_writer(root, overrides) do
    attrs = Keyword.get(overrides, :attrs, %{})
    overrides = Keyword.delete(overrides, :attrs)

    defaults = [
      root: root,
      min_free_bytes: 1,
      free_bytes: fn _root -> @ample_disk end,
      global_quota_bytes: 1_024
    ]

    Outputs.open_writer(
      Map.merge(
        %{kind: "test_output", name: "test.log", metadata: %{"source" => "test"}},
        attrs
      ),
      Keyword.merge(defaults, overrides)
    )
  end

  defp scoped_records(root) do
    project =
      %IexCode.Projects.Project{}
      |> IexCode.Projects.Project.changeset(%{
        name: "artifact-scope",
        root_path: Path.join(root, "workspace")
      })
      |> Repo.insert!()

    {:ok, session} = IexCode.Sessions.create_session(%{project_id: project.id, title: "scope"})

    {:ok, other_session} =
      IexCode.Sessions.create_session(%{project_id: project.id, title: "other scope"})

    {:ok, operation} =
      IexCode.Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "TestAgent",
        op_type: "run_command",
        title: "scoped output"
      })

    {session, operation, other_session}
  end

  defp sha256(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp restore_env(key, nil), do: Application.delete_env(:iex_code, key)
  defp restore_env(key, value), do: Application.put_env(:iex_code, key, value)
end
