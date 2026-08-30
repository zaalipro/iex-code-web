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
  alias IexCode.{WorkspaceIdentity, WorkspacePath}

  @authority_patch_limit 256 * 1_024

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
    with :ok <- verify_expected_identity(project_root, file_path, opts),
         {:ok, {file_diff, hunk}} <- find_target_hunk(project_root, file_path, hunk_id, opts) do
      mode = Keyword.get(opts, :mode, :stage)
      patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

      with :ok <- verify_expected_authority(project_root, file_path, mode_scope(mode), opts),
           :ok <- verify_hunk_binding(opts, mode_scope(mode), mode, hunk_id, patch_str),
           :ok <- before_effect(opts) do
        effect = fn git_opts ->
          with :ok <- verify_expected_authority(project_root, file_path, mode_scope(mode), opts),
               :ok <- verify_hunk_binding(opts, mode_scope(mode), mode, hunk_id, patch_str) do
            maybe_before_worktree_effect(opts, mode)

            case mode do
              :stage ->
                if Keyword.has_key?(opts, :expected_authority) do
                  exact_index_hunk_effect(project_root, file_path, patch_str, :forward, git_opts)
                else
                  stage_hunk(project_root, file_path, file_diff, hunk, git_opts)
                end

              :apply_to_file ->
                apply_hunk_to_file(project_root, file_path, file_diff, hunk, opts)
            end
          end
        end

        if mode == :stage,
          do: run_index_transaction(project_root, opts, effect),
          else: effect.([])
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
    with :ok <- verify_expected_identity(project_root, file_path, opts),
         {:ok, {file_diff, hunk}} <- find_target_hunk(project_root, file_path, hunk_id, opts) do
      patch_str = DiffParser.format_hunk_patch(file_diff, hunk)
      staged? = Keyword.get(opts, :staged, false)

      with :ok <-
             verify_expected_authority(
               project_root,
               file_path,
               if(staged?, do: :staged, else: :unstaged),
               opts
             ),
           :ok <-
             verify_hunk_binding(
               opts,
               if(staged?, do: :staged, else: :unstaged),
               if(staged?, do: :unstage, else: :reject),
               hunk_id,
               patch_str
             ),
           :ok <- before_effect(opts) do
        effect = fn git_opts ->
          with :ok <-
                 verify_expected_authority(
                   project_root,
                   file_path,
                   if(staged?, do: :staged, else: :unstaged),
                   opts
                 ),
               :ok <-
                 verify_hunk_binding(
                   opts,
                   if(staged?, do: :staged, else: :unstaged),
                   if(staged?, do: :unstage, else: :reject),
                   hunk_id,
                   patch_str
                 ),
               :ok <-
                 if(staged?,
                   do: git_scope_preflight(project_root, file_path, :staged),
                   else: :ok
                 ) do
            maybe_before_worktree_effect(opts, if(staged?, do: :unstage, else: :reject))

            if staged?,
              do:
                if(Keyword.has_key?(opts, :expected_authority),
                  do:
                    exact_index_hunk_effect(
                      project_root,
                      file_path,
                      patch_str,
                      :reverse,
                      git_opts
                    ),
                  else:
                    Git.apply_patch(
                      project_root,
                      patch_str,
                      [reverse: true, cached: true] ++ git_opts
                    )
                ),
              else:
                if(Keyword.has_key?(opts, :expected_authority),
                  do: exact_worktree_hunk_effect(project_root, file_path, patch_str, opts),
                  else: Git.apply_patch(project_root, patch_str, reverse: true)
                )
          end
        end

        result =
          if staged?,
            do: run_index_transaction(project_root, opts, effect),
            else: effect.([])

        case result do
          {:ok, _output} ->
            fetch_updated_diff(project_root, file_path)

          {:error, reason} ->
            if staged? or is_map(Keyword.get(opts, :expected_identity)) or
                 Keyword.has_key?(opts, :expected_authority) do
              {:error, reason}
            else
              case fallback_revert_hunk_in_file(project_root, file_path, hunk) do
                :ok -> fetch_updated_diff(project_root, file_path)
                {:error, _} -> {:error, reason}
              end
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
    revert_file(project_root, file_path, :all)
  end

  @spec revert_file(Path.t(), Path.t(), :staged | :unstaged | :untracked | :all) ::
          {:ok, :reverted} | {:error, term()}
  def revert_file(project_root, file_path, scope)
      when scope in [:staged, :unstaged, :untracked, :all] do
    revert_file(project_root, file_path, scope, [])
  end

  @spec revert_file(Path.t(), Path.t(), :staged | :unstaged | :untracked | :all, keyword()) ::
          {:ok, :reverted} | {:error, term()}
  def revert_file(project_root, file_path, scope, opts)
      when scope in [:staged, :unstaged, :untracked, :all] and is_list(opts) do
    opts = Keyword.put(opts, :scope, scope)

    with :ok <- verify_expected_identity(project_root, file_path, opts),
         :ok <- verify_expected_authority(project_root, file_path, scope, opts),
         :ok <- before_effect(opts) do
      effect = fn git_opts ->
        with :ok <- verify_expected_authority(project_root, file_path, scope, opts) do
          do_revert_file_scope(
            project_root,
            file_path,
            scope,
            Keyword.put(opts, :git_opts, git_opts)
          )
        end
      end

      if index_scope?(scope, opts),
        do: run_index_transaction(project_root, opts, effect),
        else: effect.([])
    end
  end

  defp mode_scope(:stage), do: :unstaged
  defp mode_scope(:apply_to_file), do: :unstaged

  defp index_scope?(:staged, opts), do: Keyword.has_key?(opts, :expected_authority)

  defp index_scope?(:all, opts) do
    case Keyword.get(opts, :expected_authority) do
      %{staged_effect: %{bytes: bytes}} when bytes > 0 -> true
      _ -> false
    end
  end

  defp index_scope?(_scope, _opts), do: false

  @doc false
  def hunk_binding(scope, operation, hunk_id, patch)
      when scope in [:staged, :unstaged] and
             operation in [:stage, :apply_to_file, :unstage, :reject] and is_binary(patch) do
    %{
      scope: scope,
      operation: operation,
      hunk_id: to_string(hunk_id),
      patch_digest: digest(patch)
    }
  end

  @doc false
  def capture_authority(root, path, scope) do
    with {:ok, status} <- Git.status(root, path_limit: 500, output_limit_bytes: 1_048_576),
         false <- status.truncated?,
         true <- authority_path_member?(status, path, scope),
         {:ok, identity} <-
           WorkspaceIdentity.capture(root, path,
             max_bytes: 2 * 1_024 * 1_024,
             allow_final_symlink: scope == :untracked
           ),
         {:ok, staged_diff} <- exact_effect_diff(root, path, :staged),
         {:ok, unstaged_diff} <- exact_effect_diff(root, path, :unstaged),
         {:ok, head_diff} <- exact_head_diff(root, path),
         {:ok, staged_hunks} <- capture_hunk_manifest(root, path, :staged),
         {:ok, unstaged_hunks} <- capture_hunk_manifest(root, path, :unstaged),
         {:ok, index} <- Git.run_git_bounded(root, ["ls-files", "--stage", "--", path], 65_536),
         {:ok, head_oid} <- bounded_oid(root, ["rev-parse", "HEAD"], []),
         {:ok, index_tree_oid} <- bounded_oid(root, ["write-tree"], []) do
      {:ok,
       %{
         version: 2,
         scope: scope,
         path: path,
         branch: Map.get(status, :branch),
         head_oid: head_oid,
         index_tree_oid: index_tree_oid,
         status_authority: status_authority(status),
         identity: identity,
         index_identity: digest(index),
         staged_diff: digest(staged_diff),
         unstaged_diff: digest(unstaged_diff),
         staged_effect: effect_manifest(staged_diff),
         unstaged_effect: effect_manifest(unstaged_diff),
         head_effect: effect_manifest(head_diff),
         staged_hunks: staged_hunks,
         unstaged_hunks: unstaged_hunks
       }}
    else
      _ -> {:error, :stale_git_snapshot}
    end
  end

  defp verify_expected_authority(root, path, scope, opts) do
    case Keyword.fetch(opts, :expected_authority) do
      :error ->
        :ok

      {:ok, expected} when is_map(expected) ->
        with {:ok, current} <- capture_authority(root, path, scope),
             true <- authority_matches?(expected, current) do
          :ok
        else
          _ -> {:error, :stale_git_snapshot}
        end

      {:ok, _invalid} ->
        {:error, :stale_git_snapshot}
    end
  end

  defp authority_matches?(expected, current) when is_map(expected) and is_map(current) do
    expected == current
  end

  defp authority_matches?(_, _), do: false

  defp verify_hunk_binding(opts, scope, operation, hunk_id, patch) do
    case Keyword.fetch(opts, :expected_authority) do
      :error ->
        :ok

      {:ok, _authority} ->
        expected = hunk_binding(scope, operation, hunk_id, patch)
        authority = Keyword.fetch!(opts, :expected_authority)

        manifest =
          Map.get(authority, if(scope == :staged, do: :staged_hunks, else: :unstaged_hunks), [])

        if Keyword.get(opts, :expected_hunk) == expected and
             Enum.any?(manifest, fn entry ->
               entry.hunk_id == expected.hunk_id and entry.patch_digest == expected.patch_digest
             end),
           do: :ok,
           else: {:error, :stale_git_snapshot}
    end
  end

  defp authority_path_member?(status, path, :staged),
    do: Enum.any?(status.staged, &status_path_match?(&1, path))

  defp authority_path_member?(status, path, :unstaged),
    do: Enum.any?(status.unstaged, &status_path_match?(&1, path))

  defp authority_path_member?(status, path, :untracked), do: path in status.untracked

  defp authority_path_member?(status, path, :all),
    do:
      authority_path_member?(status, path, :staged) or
        authority_path_member?(status, path, :unstaged) or
        authority_path_member?(status, path, :untracked)

  defp authority_path_member?(_, _, _), do: false

  defp status_path_match?(entry, path),
    do: entry.path == path or Map.get(entry, :old_path) == path

  defp status_authority(status) do
    status
    |> Map.take([:branch, :staged, :unstaged, :untracked, :conflicted])
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp exact_effect_diff(root, path, scope) do
    case Git.diff_bounded(root,
           staged: scope == :staged,
           binary: true,
           full_index: true,
           no_textconv: true,
           paths: [path],
           unified: 2_147_483_647,
           max_bytes: @authority_patch_limit,
           producer_limit_bytes: @authority_patch_limit + 1
         ) do
      {:ok, %{content: content, truncated?: false}} -> {:ok, content}
      _ -> {:error, :stale_git_snapshot}
    end
  end

  defp exact_head_diff(root, path) do
    case Git.diff_bounded(root,
           commit: "HEAD",
           binary: true,
           full_index: true,
           no_textconv: true,
           paths: [path],
           unified: 2_147_483_647,
           max_bytes: @authority_patch_limit,
           producer_limit_bytes: @authority_patch_limit + 1
         ) do
      {:ok, %{content: content, truncated?: false}} -> {:ok, content}
      _ -> {:error, :stale_git_snapshot}
    end
  end

  defp effect_manifest(patch) when is_binary(patch) do
    %{sha256: digest(patch), bytes: byte_size(patch)}
  end

  defp capture_hunk_manifest(root, path, scope) do
    case Git.diff_bounded(root,
           paths: [path],
           staged: scope == :staged,
           unified: 3,
           max_bytes: @authority_patch_limit,
           producer_limit_bytes: @authority_patch_limit + 1
         ) do
      {:ok, %{content: content, truncated?: false}} ->
        with {:ok, file_diffs} <- DiffParser.parse(content) do
          manifests =
            for file_diff <- file_diffs,
                status_entry_matches_path?(file_diff, path),
                hunk <- file_diff.hunks do
              %{
                hunk_id: to_string(hunk.id),
                patch_digest: digest(DiffParser.format_hunk_patch(file_diff, hunk))
              }
            end

          {:ok, manifests}
        end

      _ ->
        {:error, :stale_git_snapshot}
    end
  end

  defp digest(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  defp before_effect(opts) do
    case Keyword.get(opts, :before_effect) do
      fun when is_function(fun, 0) ->
        _ = fun.()
        :ok

      _ ->
        :ok
    end
  end

  defp run_index_transaction(root, opts, effect) do
    Git.with_index_transaction(root, fn git_opts ->
      previous = Process.get(:iex_code_git_index_file)
      index_file = git_opts |> Keyword.get(:env, []) |> List.keyfind("GIT_INDEX_FILE", 0)
      if index_file, do: Process.put(:iex_code_git_index_file, elem(index_file, 1))

      try do
        case Keyword.get(opts, :before_index_transaction) do
          fun when is_function(fun, 0) -> _ = fun.()
          _ -> :ok
        end

        effect.(git_opts)
      after
        if previous,
          do: Process.put(:iex_code_git_index_file, previous),
          else: Process.delete(:iex_code_git_index_file)
      end
    end)
  end

  defp maybe_before_worktree_effect(opts, operation)
       when operation in [:reject, :apply_to_file] do
    case Keyword.get(opts, :before_worktree_effect) do
      fun when is_function(fun, 0) -> _ = fun.()
      _ -> :ok
    end
  end

  defp maybe_before_worktree_effect(_opts, _operation), do: :ok

  defp exact_index_hunk_effect(root, path, selected_patch, direction, git_opts) do
    with {:ok, base_index} <- index_file_from_opts(git_opts),
         {:ok, full_patch} <-
           build_full_context_hunk_patch(root, path, base_index, selected_patch, direction),
         {:ok, output} <-
           Git.apply_patch(
             root,
             full_patch,
             [cached: true, context: 2_147_483_647, whitespace: "nowarn"] ++ git_opts
           ) do
      {:ok, output}
    else
      _ -> {:error, :stale_git_snapshot}
    end
  end

  defp exact_worktree_hunk_effect(root, path, selected_patch, opts) do
    authority = Keyword.fetch!(opts, :expected_authority)
    scratch = scratch_index_path(root)

    try do
      with {:ok, index_path} <- repository_index_path(root),
           :ok <- File.cp(index_path, scratch),
           :ok <- File.chmod(scratch, 0o600),
           {:ok, worktree_patch} <-
             verified_effect_patch(
               root,
               path,
               :unstaged,
               Map.fetch!(authority, :unstaged_effect)
             ),
           scratch_opts = [env: [{"GIT_INDEX_FILE", scratch}]],
           {:ok, _} <- Git.apply_patch(root, worktree_patch, [cached: true] ++ scratch_opts),
           {:ok, full_patch} <-
             build_full_context_hunk_patch(root, path, scratch, selected_patch, :reverse),
           {:ok, output} <-
             Git.apply_patch(root, full_patch,
               reverse: false,
               context: 2_147_483_647,
               whitespace: "nowarn"
             ) do
        {:ok, output}
      else
        _ -> {:error, :stale_git_snapshot}
      end
    after
      File.rm(scratch)
      File.rm(scratch <> ".lock")
    end
  end

  defp build_full_context_hunk_patch(root, path, base_index, selected_patch, direction) do
    desired_index = scratch_index_path(root)
    base_opts = [env: [{"GIT_INDEX_FILE", base_index}]]
    desired_opts = [env: [{"GIT_INDEX_FILE", desired_index}]]

    try do
      with :ok <- File.cp(base_index, desired_index),
           :ok <- File.chmod(desired_index, 0o600),
           {:ok, base_tree} <- bounded_oid(root, ["write-tree"], base_opts),
           {:ok, _} <-
             Git.apply_patch(
               root,
               selected_patch,
               [cached: true, reverse: direction == :reverse] ++ desired_opts
             ),
           {:ok, desired_tree} <- bounded_oid(root, ["write-tree"], desired_opts),
           {:ok, full_patch} <-
             Git.run_git_bounded(
               root,
               [
                 "diff",
                 "--binary",
                 "--full-index",
                 "--no-ext-diff",
                 "--no-textconv",
                 "--no-renames",
                 "-U2147483647",
                 base_tree,
                 desired_tree,
                 "--",
                 path
               ],
               @authority_patch_limit
             ),
           :ok <- validate_exact_effect_patch(full_patch, path) do
        {:ok, full_patch}
      else
        _ -> {:error, :stale_git_snapshot}
      end
    after
      File.rm(desired_index)
      File.rm(desired_index <> ".lock")
    end
  end

  defp bounded_oid(root, args, opts) do
    case Git.run_git_bounded(root, args, 256, opts) do
      {:ok, output} ->
        oid = String.trim(output)

        if Regex.match?(~r/\A[0-9a-f]{40,64}\z/, oid),
          do: {:ok, oid},
          else: {:error, :invalid_oid}

      error ->
        error
    end
  end

  defp validate_exact_effect_patch(patch, path) do
    with true <- patch != "",
         {:ok, [file_diff]} <- DiffParser.parse(patch),
         true <- file_diff.status == :modified,
         true <- not file_diff.binary?,
         true <- status_entry_matches_path?(file_diff, path) do
      :ok
    else
      _ -> {:error, :invalid_exact_patch}
    end
  end

  defp repository_index_path(root) do
    case Git.run_git_bounded(
           root,
           ["rev-parse", "--path-format=absolute", "--git-path", "index"],
           4_096
         ) do
      {:ok, output} ->
        path = String.trim(output)

        if Path.type(path) == :absolute and File.regular?(path),
          do: {:ok, path},
          else: {:error, :invalid_index_path}

      error ->
        error
    end
  end

  defp index_file_from_opts(opts) do
    case opts |> Keyword.get(:env, []) |> List.keyfind("GIT_INDEX_FILE", 0) do
      {"GIT_INDEX_FILE", path} when is_binary(path) -> {:ok, path}
      _ -> {:error, :missing_index_transaction}
    end
  end

  defp scratch_index_path(root) do
    Path.join(root, ".git/index.iex-hunk-#{System.unique_integer([:positive])}")
  end

  defp do_revert_file_scope(project_root, file_path, scope, opts) do
    if Keyword.has_key?(opts, :expected_authority) do
      do_exact_revert_file_scope(project_root, file_path, scope, opts)
    else
      do_legacy_revert_file_scope(project_root, file_path, scope, opts)
    end
  end

  defp do_exact_revert_file_scope(project_root, file_path, :untracked, _opts) do
    with {:ok, _canonical} <- WorkspacePath.resolve(project_root, file_path),
         :ok <- reject_final_symlink(project_root, file_path) do
      remove_file(Path.expand(file_path, project_root))
    else
      _ -> {:error, :stale_git_snapshot}
    end
  end

  defp do_exact_revert_file_scope(project_root, file_path, scope, opts) do
    authority = Keyword.fetch!(opts, :expected_authority)
    git_opts = Keyword.get(opts, :git_opts, [])
    staged_effect = Map.get(authority, :staged_effect, %{})
    unstaged_effect = Map.get(authority, :unstaged_effect, %{})
    staged_bytes = Map.get(staged_effect, :bytes)
    unstaged_bytes = Map.get(unstaged_effect, :bytes)

    with :ok <-
           if(scope in [:staged, :all],
             do: git_scope_preflight(project_root, file_path, scope),
             else: :ok
           ) do
      case scope do
        :staged ->
          with {:ok, patch} <-
                 verified_effect_patch(project_root, file_path, :staged, staged_effect),
               false <- patch == "" do
            exact_reverse_apply(project_root, patch, [cached: true] ++ git_opts)
          else
            _ -> {:error, :unsupported_atomic_effect}
          end

        :unstaged ->
          with {:ok, patch} <-
                 verified_effect_patch(project_root, file_path, :unstaged, unstaged_effect),
               false <- patch == "" do
            exact_reverse_apply(project_root, patch, git_opts)
          else
            _ -> {:error, :unsupported_atomic_effect}
          end

        :all when staged_bytes == 0 ->
          with {:ok, patch} <-
                 verified_effect_patch(project_root, file_path, :unstaged, unstaged_effect),
               false <- patch == "" do
            exact_reverse_apply(project_root, patch, git_opts)
          else
            _ -> {:error, :unsupported_atomic_effect}
          end

        :all when unstaged_bytes == 0 ->
          with {:ok, patch} <-
                 verified_effect_patch(project_root, file_path, :staged, staged_effect),
               false <- patch == "" do
            exact_reverse_apply(project_root, patch, [index: true] ++ git_opts)
          else
            _ -> {:error, :unsupported_atomic_effect}
          end

        :all ->
          {:error, :unsupported_atomic_effect}

        _ ->
          {:error, :unsupported_atomic_effect}
      end
    end
  end

  defp verified_effect_patch(root, path, scope, expected) do
    with {:ok, patch} <- exact_effect_diff(root, path, scope),
         true <- effect_manifest(patch) == expected do
      {:ok, patch}
    else
      _ -> {:error, :stale_git_snapshot}
    end
  end

  defp exact_reverse_apply(root, patch, opts) do
    case Git.apply_patch(root, patch, [reverse: true, whitespace: "nowarn"] ++ opts) do
      {:ok, _output} -> {:ok, :reverted}
      {:error, _reason} -> {:error, :stale_git_snapshot}
    end
  end

  defp do_legacy_revert_file_scope(project_root, file_path, scope, opts) do
    if scope == :untracked do
      with {:ok, _canonical} <- WorkspacePath.resolve(project_root, file_path) do
        # Remove the lexical final component so a symlink is unlinked rather
        # than following it to a target file.
        remove_file(Path.expand(file_path, project_root))
      else
        {:error, reason} -> {:error, {:invalid_path, file_path, reason}}
      end
    else
      with :ok <- reject_final_symlink(project_root, file_path),
           {:ok, git_path, full_path} <- verified_git_path(project_root, file_path, opts) do
        do_revert_file(project_root, git_path, full_path, scope)
      else
        {:error, reason} -> {:error, {:invalid_path, file_path, reason}}
      end
    end
  end

  defp verified_git_path(project_root, file_path, opts) do
    case Keyword.get(opts, :expected_identity) do
      %{canonical: canonical} ->
        with {:ok, canonical_root} <- resolve_file_path(project_root, ""),
             relative when relative != "" <- Path.relative_to(canonical, canonical_root),
             false <- String.starts_with?(relative, "..") do
          {:ok, relative, canonical}
        else
          _ -> {:error, :stale_git_snapshot}
        end

      _ ->
        with {:ok, full_path} <- resolve_file_path(project_root, file_path),
             {:ok, canonical_root} <- resolve_file_path(project_root, "") do
          {:ok, Path.relative_to(full_path, canonical_root), full_path}
        end
    end
  end

  defp reject_final_symlink(project_root, file_path) do
    case File.lstat(Path.expand(file_path, project_root)) do
      {:ok, %{type: :symlink}} -> {:error, :symlink_not_allowed}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_revert_file(project_root, file_path, _full_path, :staged) do
    if local_git_repository?(project_root) do
      case git_scope_preflight(project_root, file_path, :staged) do
        :ok ->
          case Git.restore_file(project_root, file_path, staged: true, worktree: false) do
            {:ok, _} -> {:ok, :reverted}
            error -> error
          end

        error ->
          error
      end
    else
      {:error, :not_a_git_repo}
    end
  end

  defp do_revert_file(project_root, file_path, full_path, :unstaged) do
    if local_git_repository?(project_root) do
      case Git.restore_file(project_root, file_path, staged: false, worktree: true) do
        {:ok, _} -> {:ok, :reverted}
        error -> error
      end
    else
      backup_non_git_file(full_path)
    end
  end

  defp do_revert_file(_project_root, _file_path, full_path, :untracked) do
    remove_file(full_path)
  end

  defp do_revert_file(project_root, file_path, full_path, :all) do
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
    case Git.status(project_root, path_limit: 500, output_limit_bytes: 1_048_576) do
      {:ok, status} ->
        cond do
          file_path in status.untracked ->
            remove_file(full_path)

          git_scope_supported?(status, file_path, :all) and
              Git.restore_shape_allowed(project_root, file_path,
                staged: true,
                worktree: true
              ) == :ok ->
            # One Git command updates the index and worktree from HEAD. Avoid
            # the former unstage-then-restore sequence, which could report an
            # error after already partially mutating the index.
            case Git.run_git(project_root, ["checkout", "HEAD", "--", file_path]) do
              {:ok, _} -> {:ok, :reverted}
              error -> error
            end

          true ->
            {:error, :unsupported_git_shape}
        end

      {:error, :not_a_git_repo} ->
        # A stale/broken .git marker is still not authority to delete a file.
        backup_non_git_file(full_path)

      error ->
        error
    end
  end

  # Rename/copy and index-added targets have no single-path HEAD restore that
  # satisfies the requested scope. Reject them before any effect instead of
  # leaving a staged deletion or untracked path after a partial failure.
  defp git_scope_preflight(project_root, file_path, scope) do
    restore_opts =
      if scope == :staged,
        do: [staged: true, worktree: false],
        else: [staged: true, worktree: true]

    with :ok <- Git.restore_shape_allowed(project_root, file_path, restore_opts),
         {:ok, status} <-
           Git.status(project_root, path_limit: 500, output_limit_bytes: 1_048_576) do
      if git_scope_supported?(status, file_path, scope),
        do: :ok,
        else: {:error, :unsupported_git_shape}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_scope_supported?(status, file_path, :staged) do
    not status.truncated? and not Enum.any?(status.conflicted, &(&1.path == file_path)) and
      not Enum.any?(status.staged, fn entry ->
        status_entry_matches_path?(entry, file_path) and rename_or_copy_status?(entry.status)
      end)
  end

  defp git_scope_supported?(status, file_path, :all) do
    not status.truncated? and not Enum.any?(status.conflicted, &(&1.path == file_path)) and
      not Enum.any?(status.staged, fn entry ->
        status_entry_matches_path?(entry, file_path) and
          (rename_or_copy_status?(entry.status) or entry.status in [:added, "added"])
      end)
  end

  defp status_entry_matches_path?(entry, path) do
    entry.path == path or Map.get(entry, :old_path) == path
  end

  defp rename_or_copy_status?(status) when is_atom(status),
    do: status |> Atom.to_string() |> rename_or_copy_status?()

  defp rename_or_copy_status?(status) when is_binary(status) do
    normalized = String.downcase(status)
    String.contains?(normalized, "renam") or String.contains?(normalized, "cop")
  end

  defp rename_or_copy_status?(_status), do: true

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
    if match?({:ok, _}, File.lstat(full_path)) do
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
  def accept_all_hunks(project_root, file_path, opts \\ []) do
    stage_result =
      case Keyword.get(opts, :_stage) do
        fun when is_function(fun, 2) ->
          fun.(file_path, project_root)

        _ ->
          if Mix.env() == :test do
            case Application.get_env(:iex_code, :workspace_stage_mutator) do
              fun when is_function(fun, 2) -> fun.(file_path, project_root)
              _ -> Git.stage(file_path, project_root)
            end
          else
            Git.stage(file_path, project_root)
          end
      end

    case stage_result do
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
    if Keyword.has_key?(opts, :expected_authority) do
      resolve_strict_diff_text(project_root, file_path, opts)
    else
      resolve_legacy_diff_text(project_root, file_path, opts)
    end
  end

  defp resolve_strict_diff_text(project_root, file_path, opts) do
    supplied = Keyword.get(opts, :diff)
    staged = Keyword.get(opts, :staged, false)

    case Git.diff_bounded(project_root,
           paths: [file_path],
           staged: staged,
           max_bytes: 8 * 1_024 * 1_024,
           producer_limit_bytes: 8 * 1_024 * 1_024
         ) do
      {:ok, %{content: current, truncated?: false}}
      when is_binary(supplied) and supplied != "" and supplied == current ->
        {:ok, current}

      _ ->
        {:error, :stale_git_snapshot}
    end
  end

  defp resolve_legacy_diff_text(project_root, file_path, opts) do
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

  defp stage_hunk(project_root, file_path, file_diff, hunk, git_opts) do
    patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

    case Git.apply_patch(project_root, patch_str, [cached: true] ++ git_opts) do
      {:ok, _output} ->
        fetch_updated_diff(project_root, file_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_hunk_to_file(project_root, file_path, file_diff, hunk, opts) do
    patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

    case apply_patch_to_file(project_root, patch_str, opts) do
      {:ok, _output} ->
        fetch_updated_diff(project_root, file_path)

      {:error, reason} ->
        if Keyword.has_key?(opts, :expected_identity) do
          {:error, reason}
        else
          case fallback_apply_hunk_in_file(project_root, file_path, hunk) do
            :ok -> fetch_updated_diff(project_root, file_path)
            {:error, err} -> {:error, err}
          end
        end
    end
  end

  # A narrow test seam lets the destructive fallback policy be exercised
  # deterministically without relying on a filesystem race. Production uses
  # the regular Git adapter.
  defp apply_patch_to_file(project_root, patch_str, opts) do
    case Keyword.get(opts, :_apply_patch) do
      fun when is_function(fun, 2) -> fun.(project_root, patch_str)
      _ -> Git.apply_patch(project_root, patch_str)
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

  defp verify_expected_identity(root, path, opts) do
    case Keyword.fetch(opts, :expected_identity) do
      :error ->
        :ok

      {:ok, expected} when is_map(expected) ->
        scope = Keyword.get(opts, :scope)

        with {:ok, current} <-
               WorkspaceIdentity.capture(root, path,
                 max_bytes: 2 * 1_024 * 1_024,
                 allow_final_symlink: scope == :untracked
               ),
             true <- current == expected do
          :ok
        else
          _ -> {:error, :stale_git_snapshot}
        end

      {:ok, _invalid} ->
        {:error, :stale_git_snapshot}
    end
  end
end
