defmodule IexCode.Tools.Git.HunkOps do
  @moduledoc """
  Granular diff hunk management and file reversion engine.

  Provides capabilities to:
  - Accept individual hunks (stage to Git index or apply to working tree)
  - Reject individual hunks (reverse/discard hunk changes from working tree)
  - Revert entire files (discard all unstaged and staged changes)
  - Accept or reject all hunks in a file
  - Seamlessly integrate with `IexCode.Tools.Git` and `IexCode.Tools.MultiPatch`
  """

  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.DiffParser
  alias IexCode.Tools.MultiPatch
  alias IexCode.WorkspacePath

  @doc """
  Accepts a specific hunk.
  In a Git repository with unstaged changes, staging the hunk moves it into the Git index.
  In `:apply_to_file` mode or patch workflow, applies the hunk to the working copy.

  ## Options
  - `:diff` - Raw diff string if already computed
  - `:mode` - `:stage` (default) or `:apply_to_file`
  - `:staged` - Boolean, whether to look in staged diff
  """
  @spec accept_hunk(Path.t(), Path.t(), String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def accept_hunk(project_root, file_path, hunk_id, opts \\ []) do
    with {:ok, {file_diff, hunk}} <- find_target_hunk(project_root, file_path, hunk_id, opts) do
      mode = Keyword.get(opts, :mode, :stage)

      case mode do
        :stage ->
          stage_hunk(project_root, file_path, file_diff, hunk)

        :apply_to_file ->
          apply_hunk_to_file(project_root, file_path, file_diff, hunk)
      end
    end
  end

  @doc """
  Rejects / discards changes in a specific hunk.

  By default the hunk is reverse-applied to the working tree. With `staged: true`
  the hunk is reverse-applied to the Git index instead (un-staging that hunk's
  changes), and no working-tree fallback is attempted.
  """
  @spec reject_hunk(Path.t(), Path.t(), String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def reject_hunk(project_root, file_path, hunk_id, opts \\ []) do
    with {:ok, {file_diff, hunk}} <- find_target_hunk(project_root, file_path, hunk_id, opts) do
      patch_str = DiffParser.format_hunk_patch(file_diff, hunk)
      staged? = Keyword.get(opts, :staged, false)

      result =
        if staged? do
          Git.apply_patch(project_root, patch_str, reverse: true, cached: true)
        else
          Git.apply_patch(project_root, patch_str, reverse: true)
        end

      case result do
        {:ok, _output} ->
          fetch_updated_diff(project_root, file_path)

        {:error, reason} ->
          if staged? do
            {:error, reason}
          else
            # Fallback to in-memory replacement on the file
            case fallback_revert_hunk_in_file(project_root, file_path, hunk) do
              :ok -> fetch_updated_diff(project_root, file_path)
              {:error, _} -> {:error, reason}
            end
          end
      end
    end
  end

  @doc """
  Reverts a specific hunk. Alias for `reject_hunk/4`.
  """
  defdelegate revert_hunk(project_root, file_path, hunk_id, opts \\ []),
    to: __MODULE__,
    as: :reject_hunk

  @doc """
  Unstages a specific hunk from the Git index without modifying the working tree copy.
  """
  @spec unstage_hunk(Path.t(), Path.t(), String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def unstage_hunk(project_root, file_path, hunk_id, opts \\ []) do
    reject_hunk(project_root, file_path, hunk_id, Keyword.put(opts, :staged, true))
  end

  @doc """
  Reverts all changes to a specific file (staged and unstaged), restoring the HEAD revision.
  If the file is untracked (newly created), it is safely removed from disk.
  In a non-Git workspace there is no HEAD to restore to, so the file is moved
  aside to `<path>.bak` instead of being deleted outright.
  """
  @spec revert_file(Path.t(), Path.t()) :: {:ok, :reverted} | {:error, term()}
  def revert_file(project_root, file_path) do
    with {:ok, full_path} <- resolve_file_path(project_root, file_path),
         {:ok, canonical_root} <- resolve_file_path(project_root, "") do
      git_path = Path.relative_to(full_path, canonical_root)
      do_revert_file(project_root, git_path, full_path)
    else
      {:error, reason} -> {:error, {:invalid_path, file_path, reason}}
    end
  end

  defp do_revert_file(project_root, file_path, full_path) do
    # A workspace is a Git capability only when its own root contains a real
    # .git directory/file. Never inherit a parent checkout merely because a CI
    # temp directory happens to live below it; that could restore or delete a
    # file against the wrong repository.
    if local_git_repository?(project_root) do
      do_revert_git_file(project_root, file_path, full_path)
    else
      backup_non_git_file(full_path)
    end
  end

  defp do_revert_git_file(project_root, file_path, full_path) do
    case Git.status(project_root, paths: [file_path], path_limit: 4, output_limit_bytes: 32_768) do
      {:ok, status} ->
        if file_path in status.untracked do
          remove_file(full_path)
        else
          case Git.restore_file(project_root, file_path, staged: true, worktree: true) do
            {:ok, _} ->
              {:ok, :reverted}

            {:error, _} ->
              case Git.run_git(project_root, ["checkout", "HEAD", "--", file_path]) do
                {:ok, _} -> {:ok, :reverted}
                error -> error
              end
          end
        end

      {:error, :not_a_git_repo} ->
        # A stale/broken .git marker is still not authority to delete a file.
        backup_non_git_file(full_path)

      error ->
        error
    end
  end

  defp local_git_repository?(project_root) do
    case File.lstat(Path.join(project_root, ".git")) do
      {:ok, %File.Stat{type: type}} when type in [:directory, :regular] -> true
      _missing_or_unsafe -> false
    end
  end

  defp backup_non_git_file(full_path) do
    if File.exists?(full_path) do
      case File.rename(full_path, full_path <> ".bak") do
        :ok -> {:ok, :reverted}
        {:error, reason} -> {:error, {:backup_failed, reason}}
      end
    else
      {:ok, :reverted}
    end
  end

  defp remove_file(full_path) do
    if File.exists?(full_path) do
      case File.rm(full_path) do
        :ok -> {:ok, :reverted}
        {:error, reason} -> {:error, {:remove_failed, reason}}
      end
    else
      {:ok, :reverted}
    end
  end

  @doc """
  Accepts all hunks for a given file by staging the file.
  """
  @spec accept_all_hunks(Path.t(), Path.t()) :: {:ok, :accepted} | {:error, term()}
  def accept_all_hunks(project_root, file_path) do
    case Git.stage(file_path, project_root) do
      :ok -> {:ok, :accepted}
      err -> err
    end
  end

  @doc """
  Rejects all hunks for a given file. Alias for `revert_file/2`.
  """
  defdelegate reject_all_hunks(project_root, file_path), to: __MODULE__, as: :revert_file

  # --- Internal Helpers ---

  defp find_target_hunk(project_root, file_path, hunk_id, opts) do
    with {:ok, diff_text} <- resolve_diff_text(project_root, file_path, opts) do
      if String.trim(diff_text) == "" do
        {:error, :no_diff_found}
      else
        with {:ok, file_diffs} <- DiffParser.parse(diff_text) do
          normalized_path = normalize_rel_path(file_path)

          # Filter file diff matching file_path — never fall back to another
          # file's diff, that would apply hunks to the wrong target.
          target_file_diff =
            Enum.find(file_diffs, fn fd ->
              normalize_rel_path(fd.path) == normalized_path or
                normalize_rel_path(fd.new_path) == normalized_path or
                normalize_rel_path(fd.old_path) == normalized_path
            end)

          if is_nil(target_file_diff) do
            {:error, {:file_diff_not_found, file_path}}
          else
            case DiffParser.find_hunk(target_file_diff, hunk_id) do
              {:ok, {fd, hunk}} -> {:ok, {fd, hunk}}
              {:error, _} -> {:error, {:hunk_not_found, hunk_id}}
            end
          end
        end
      end
    end
  end

  defp resolve_diff_text(project_root, file_path, opts) do
    case Keyword.get(opts, :diff) do
      d when is_binary(d) and d != "" ->
        {:ok, d}

      _ ->
        staged = Keyword.get(opts, :staged, false)

        case Git.diff_bounded(project_root,
               paths: [file_path],
               staged: staged,
               max_bytes: 8 * 1_024 * 1_024
             ) do
          {:ok, %{content: output, truncated?: false}} -> {:ok, output}
          {:ok, %{truncated?: true}} -> {:error, :diff_too_large}
          {:error, reason} -> {:error, {:diff_failed, reason}}
        end
    end
  end

  defp stage_hunk(project_root, file_path, file_diff, hunk) do
    patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

    case Git.apply_patch(project_root, patch_str, cached: true) do
      {:ok, _output} ->
        fetch_updated_diff(project_root, file_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_hunk_to_file(project_root, file_path, file_diff, hunk) do
    patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

    case Git.apply_patch(project_root, patch_str) do
      {:ok, _output} ->
        fetch_updated_diff(project_root, file_path)

      {:error, _reason} ->
        case fallback_apply_hunk_in_file(project_root, file_path, hunk) do
          :ok -> fetch_updated_diff(project_root, file_path)
          {:error, err} -> {:error, err}
        end
    end
  end

  defp fetch_updated_diff(project_root, file_path) do
    case Git.diff_bounded(project_root, paths: [file_path], max_bytes: 8 * 1_024 * 1_024) do
      {:ok, %{content: remaining_diff, truncated?: false}} -> {:ok, remaining_diff}
      {:ok, %{truncated?: true}} -> {:error, :diff_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback_revert_hunk_in_file(project_root, file_path, hunk) do
    case resolve_file_path(project_root, file_path) do
      {:ok, full_path} -> do_fallback_revert_hunk_in_file(full_path, hunk)
      {:error, reason} -> {:error, {:invalid_path, file_path, reason}}
    end
  end

  defp do_fallback_revert_hunk_in_file(full_path, hunk) do
    if not File.exists?(full_path) do
      {:error, :file_not_found}
    else
      content = File.read!(full_path)

      target = hunk_lines_text(hunk, [:context, :addition])
      replacement = hunk_lines_text(hunk, [:context, :deletion])

      cond do
        target == "" and replacement == "" ->
          :ok

        target == "" ->
          # Hunk contains only deletions: reverting means re-inserting the
          # deleted lines at their original position — never overwrite the file.
          insert_lines_at(full_path, content, hunk.old_start, replacement)

        true ->
          replace_anchored(full_path, content, hunk.old_start, target, replacement,
            error_tag: :fallback_revert_failed
          )
      end
    end
  end

  defp fallback_apply_hunk_in_file(project_root, file_path, hunk) do
    case resolve_file_path(project_root, file_path) do
      {:ok, full_path} -> do_fallback_apply_hunk_in_file(full_path, hunk)
      {:error, reason} -> {:error, {:invalid_path, file_path, reason}}
    end
  end

  defp do_fallback_apply_hunk_in_file(full_path, hunk) do
    if not File.exists?(full_path) do
      {:error, :file_not_found}
    else
      content = File.read!(full_path)

      target = hunk_lines_text(hunk, [:context, :deletion])
      replacement = hunk_lines_text(hunk, [:context, :addition])

      if target == "" do
        # Hunk contains only additions: insert them at the new-file position.
        insert_lines_at(full_path, content, max(hunk.new_start, 1), replacement)
      else
        replace_anchored(full_path, content, hunk.old_start, target, replacement,
          error_tag: :fallback_apply_failed
        )
      end
    end
  end

  defp hunk_lines_text(hunk, types) do
    hunk.lines
    |> Enum.filter(&(&1.type in types))
    |> Enum.map(& &1.content)
    |> Enum.join("\n")
  end

  # Anchors the search region on the hunk's declared old_start line so the
  # replacement can only occur near where the hunk belongs, never elsewhere
  # in the file.
  defp replace_anchored(full_path, content, anchor_line, target, replacement, opts) do
    error_tag = Keyword.fetch!(opts, :error_tag)

    case split_at_line(content, anchor_line) do
      {prefix, region} ->
        case MultiPatch.patch_string(region, target, replacement, allow_multiple: false) do
          {:ok, %{content: new_region}} ->
            File.write!(full_path, prefix <> new_region)
            :ok

          {:error, _} ->
            {:error, error_tag}
        end

      :error ->
        {:error, error_tag}
    end
  end

  # Splits content into {text before 1-based line_number, text from that line on}.
  defp split_at_line(content, line_number) when line_number >= 1 do
    offset =
      content
      |> String.splitter("\n")
      |> Enum.take(line_number - 1)
      |> Enum.reduce(0, fn line, acc -> acc + byte_size(line) + 1 end)

    cond do
      offset > byte_size(content) ->
        :error

      offset == 0 ->
        {"", content}

      true ->
        <<prefix::binary-size(offset), region::binary>> = content
        {prefix, region}
    end
  end

  defp insert_lines_at(full_path, content, line_number, inserted) do
    new_content =
      case split_at_line(content, max(line_number, 1)) do
        {prefix, region} ->
          cond do
            region == "" and prefix != "" and not String.ends_with?(prefix, "\n") ->
              prefix <> "\n" <> inserted

            region == "" ->
              prefix <> inserted <> "\n"

            true ->
              prefix <> inserted <> "\n" <> region
          end

        # Anchor beyond EOF: append at the end of the file instead of crashing.
        :error ->
          cond do
            content == "" -> inserted <> "\n"
            String.ends_with?(content, "\n") -> content <> inserted <> "\n"
            true -> content <> "\n" <> inserted <> "\n"
          end
      end

    File.write!(full_path, new_content)
    :ok
  end

  defp normalize_rel_path(nil), do: ""

  defp normalize_rel_path(path) do
    path
    |> String.trim_leading("./")
    |> String.trim_leading("/")
  end

  defp resolve_file_path(project_root, path) do
    WorkspacePath.resolve(project_root, path)
  end
end
