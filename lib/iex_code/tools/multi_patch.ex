defmodule IexCode.Tools.MultiPatch do
  @moduledoc """
  Multi-File Atomic Patching Engine.
  Applies batch patches across multiple workspace files using a 3-tier matching
  strategy (AST, Exact, Fuzzy Indentation Alignment) with atomic transactional
  rollback on any failure.
  """

  alias IexCode.Tools.MultiPatch.{Matcher, Diff, Snapshot}
  alias IexCode.WorkspacePath

  @type tier :: Matcher.tier()

  @type patch_spec :: %{
          required(:path) => Path.t(),
          required(:target) => String.t(),
          required(:replacement) => String.t(),
          optional(:tier) => tier() | :auto,
          optional(:allow_multiple) => boolean()
        }

  @type patch_result :: %{
          path: Path.t(),
          tier_used: tier(),
          original_content: String.t(),
          new_content: String.t(),
          diff: String.t()
        }

  @type patch_summary :: %{
          applied: non_neg_integer(),
          patches: [patch_result()],
          diff: String.t(),
          tiers_used: %{
            ast: non_neg_integer(),
            exact: non_neg_integer(),
            fuzzy: non_neg_integer()
          },
          transaction_id: String.t()
        }

  @doc """
  Applies a batch of patches atomically across multiple workspace files.
  If any patch fails (target not found, syntax error, or write error),
  no files remain modified and all partial changes are rolled back.
  """
  @spec apply_patches(Path.t(), [patch_spec() | map()], keyword()) ::
          {:ok, patch_summary()} | {:error, term()}
  def apply_patches(project_root, patches, opts \\ []) when is_list(patches) do
    # Phase 1: In-Memory Validation & Plan (Zero disk writes)
    case plan_patches(project_root, patches, opts) do
      {:ok, planned_patches} ->
        # Phase 2: Transactional Disk Writes with Rollback Guard
        tx_id = "tx_" <> Ecto.UUID.generate()
        execute_writes(project_root, planned_patches, tx_id, opts)

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Previews a batch of patches without modifying disk.
  Returns the unified diff and planned patch modifications.
  """
  @spec preview_patches(Path.t(), [patch_spec() | map()], keyword()) ::
          {:ok, %{diff: String.t(), patches: [patch_result()]}} | {:error, term()}
  def preview_patches(project_root, patches, opts \\ []) when is_list(patches) do
    case plan_patches(project_root, patches, opts) do
      {:ok, planned_patches} ->
        combined_diff =
          planned_patches
          |> Enum.map(& &1.diff)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")

        {:ok, %{diff: combined_diff, patches: planned_patches}}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Patches a single string in memory using the 3-tier matcher.
  """
  @spec patch_string(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{content: String.t(), tier: tier()}} | {:error, :not_found}
  defdelegate patch_string(content, target, replacement, opts \\ []), to: Matcher, as: :patch

  @doc """
  Reverts a previously applied patch transaction using its transaction ID.

  Non-destructive: before restoring a file, its current content is compared to
  the expected post-patch content; files that changed since the patch are
  skipped and flagged instead of clobbered. If any file was skipped or could
  not be restored, returns `{:error, {:partial, details}}` and keeps the
  snapshot for inspection/retry.
  """
  @spec rollback(String.t()) ::
          {:ok, %{restored_files: [Path.t()], skipped_files: [Path.t()]}}
          | {:error, term()}
  def rollback(transaction_id) do
    case Snapshot.get_snapshot(transaction_id) do
      {:ok, %{patches: patches, project_root: project_root}}
      when is_binary(project_root) and project_root != "" ->
        results = Enum.map(patches, &restore_scoped_patch(project_root, &1))

        restored = for {:restored, path} <- results, do: path
        skipped = for {:skipped, path} <- results, do: path
        failed = for {:failed, path, _reason} <- results, do: path

        if skipped == [] and failed == [] do
          Snapshot.delete_snapshot(transaction_id)
          {:ok, %{restored_files: restored, skipped_files: []}}
        else
          {:error,
           {:partial,
            %{
              restored_files: restored,
              skipped_files: skipped,
              failed_files: failed
            }}}
        end

      {:ok, _unscoped_snapshot} ->
        {:error, :missing_workspace_scope}

      {:error, :not_found} ->
        {:error, {:transaction_not_found, transaction_id}}
    end
  end

  defp restore_scoped_patch(project_root, patch) do
    case WorkspacePath.resolve(project_root, patch.path) do
      {:ok, authorized_path} -> restore_patch(%{patch | full_path: authorized_path})
      {:error, reason} -> {:failed, patch.path, {:invalid_path, reason}}
    end
  end

  defp restore_patch(p) do
    if p.file_existed? do
      case File.read(p.full_path) do
        {:ok, current} when current == p.new_content ->
          write_original(p)

        {:ok, _current} ->
          # The file changed since the patch was applied; never clobber newer edits.
          {:skipped, p.path}

        {:error, :enoent} ->
          # Deleted since the patch; restoring it would resurrect removed work.
          {:skipped, p.path}

        {:error, reason} ->
          {:failed, p.path, reason}
      end
    else
      # Patch created this file; only remove it if untouched since.
      case File.read(p.full_path) do
        {:ok, current} when current == p.new_content ->
          case File.rm(p.full_path) do
            :ok -> {:restored, p.path}
            {:error, reason} -> {:failed, p.path, reason}
          end

        {:ok, _current} ->
          {:skipped, p.path}

        {:error, :enoent} ->
          {:restored, p.path}

        {:error, reason} ->
          {:failed, p.path, reason}
      end
    end
  end

  defp write_original(p) do
    case File.write(p.full_path, p.original_content) do
      :ok -> {:restored, p.path}
      {:error, reason} -> {:failed, p.path, reason}
    end
  end

  # --- Phase 1: Planning & Validation ---

  defp plan_patches(project_root, patches, opts) do
    validate_syntax? = Keyword.get(opts, :validate_syntax, true)

    # Group patches by path so multiple patches to the same file are applied sequentially in memory
    normalized_patches = Enum.map(patches, &normalize_patch_spec/1)

    with :ok <- validate_patch_specs(normalized_patches) do
      grouped =
        Enum.group_by(normalized_patches, fn p -> p.path end)

      Enum.reduce_while(grouped, {:ok, []}, fn {rel_path, file_patches}, {:ok, acc} ->
        with {:ok, full_path} <- resolve_file_path(project_root, rel_path) do
          if not File.exists?(full_path) do
            {:halt, {:error, {:file_not_found, rel_path}}}
          else
            original_content = File.read!(full_path)
            stat = File.stat!(full_path)

            # Apply patches sequentially in memory to original_content
            res =
              Enum.reduce_while(file_patches, {:ok, original_content, []}, fn patch,
                                                                              {:ok,
                                                                               current_content,
                                                                               patch_acc} ->
                target = patch.target
                replacement = patch.replacement

                patch_opts = [
                  allow_multiple: patch.allow_multiple,
                  tier: patch.tier
                ]

                case Matcher.patch(current_content, target, replacement, patch_opts) do
                  {:ok, %{content: next_content, tier: tier_used}} ->
                    {:cont, {:ok, next_content, [{patch, tier_used} | patch_acc]}}

                  {:error, :not_found} ->
                    {:halt, {:error, {:target_not_found, rel_path, target}}}
                end
              end)

            case res do
              {:ok, final_content, applied_info} ->
                # Validate Elixir syntax if requested
                ext = Path.extname(rel_path)

                syntax_check =
                  if validate_syntax? and ext in [".ex", ".exs"] do
                    case Code.string_to_quoted(final_content) do
                      {:ok, _ast} -> :ok
                      {:error, reason} -> {:error, {:syntax_error, rel_path, inspect(reason)}}
                    end
                  else
                    :ok
                  end

                case syntax_check do
                  :ok ->
                    diff_str = Diff.unified_diff(original_content, final_content, rel_path)
                    # Determine predominant tier
                    tiers = Enum.map(applied_info, fn {_p, t} -> t end)
                    primary_tier = List.first(tiers) || :exact

                    entry = %{
                      path: rel_path,
                      full_path: full_path,
                      file_existed?: true,
                      original_content: original_content,
                      new_content: final_content,
                      tier_used: primary_tier,
                      all_tiers: tiers,
                      diff: diff_str,
                      # Captured for staleness detection between plan and write
                      stat: %{size: stat.size, mtime: stat.mtime}
                    }

                    {:cont, {:ok, [entry | acc]}}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end
        else
          {:error, reason} -> {:halt, {:error, {:invalid_path, rel_path, reason}}}
        end
      end)
      |> case do
        {:ok, planned} -> {:ok, Enum.reverse(planned)}
        {:error, _} = err -> err
      end
    end
  end

  defp validate_patch_specs(patches) do
    case Enum.find(patches, &(is_nil(&1.path) or &1.target == "")) do
      nil -> :ok
      %{path: nil} -> {:error, :missing_path}
      %{path: path} -> {:error, {:empty_target, path}}
    end
  end

  # --- Phase 2: Transactional Execution ---

  defp execute_writes(project_root, planned_patches, tx_id, opts) do
    # Save the snapshot BEFORE the first write so a crash mid-write still
    # leaves a recoverable transaction record.
    session_id = Keyword.get(opts, :session_id)
    run_id = Keyword.get(opts, :run_id)

    with :ok <-
           Snapshot.save_snapshot(tx_id, planned_patches,
             session_id: session_id,
             run_id: run_id,
             project_root: project_root
           ) do
      case verify_targets_unchanged(planned_patches) do
        :ok ->
          write_all(planned_patches, tx_id)

        {:error, :stale_target} = err ->
          Snapshot.delete_snapshot(tx_id)
          err
      end
    else
      {:error, reason} -> {:error, {:snapshot_persist_failed, reason}}
    end
  end

  # Pre-flight check: fail the whole transaction before touching disk if any
  # target file changed (size/mtime) between planning and writing.
  defp verify_targets_unchanged(planned_patches) do
    Enum.find_value(planned_patches, :ok, fn plan ->
      if target_stale?(plan), do: {:error, :stale_target}
    end)
  end

  defp target_stale?(plan) do
    case File.stat(plan.full_path) do
      {:ok, stat} ->
        stat.size != plan.stat.size or stat.mtime != plan.stat.mtime

      {:error, _reason} ->
        true
    end
  end

  defp write_all(planned_patches, tx_id) do
    Enum.reduce_while(planned_patches, {:ok, []}, fn plan, {:ok, written} ->
      File.mkdir_p!(Path.dirname(plan.full_path))

      case atomic_write(plan) do
        :ok ->
          {:cont, {:ok, [plan | written]}}

        {:error, :stale_target} ->
          rollback_written(written)
          Snapshot.delete_snapshot(tx_id)
          {:halt, {:error, :stale_target}}

        {:error, reason} ->
          # Immediate Rollback
          rollback_written(written)
          Snapshot.delete_snapshot(tx_id)
          {:halt, {:error, {:write_failed, plan.path, reason, :rolled_back}}}
      end
    end)
    |> case do
      {:ok, written_plans} ->
        # Count tier breakdowns
        all_tiers = Enum.flat_map(planned_patches, & &1.all_tiers)

        ast_count = Enum.count(all_tiers, &(&1 == :ast))
        exact_count = Enum.count(all_tiers, &(&1 == :exact))
        fuzzy_count = Enum.count(all_tiers, &(&1 == :fuzzy))

        combined_diff =
          planned_patches
          |> Enum.map(& &1.diff)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")

        summary = %{
          applied: length(written_plans),
          patches: planned_patches,
          diff: combined_diff,
          tiers_used: %{
            ast: ast_count,
            exact: exact_count,
            fuzzy: fuzzy_count
          },
          transaction_id: tx_id
        }

        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Atomic single-file write: write to a temp file in the same directory, then
  # rename over the target. Re-checks staleness immediately before writing.
  defp atomic_write(plan) do
    if target_stale?(plan) do
      {:error, :stale_target}
    else
      tmp_path = tmp_path(plan.full_path)

      try do
        File.write!(tmp_path, plan.new_content)

        case File.rename(tmp_path, plan.full_path) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
      rescue
        exception -> {:error, {:temp_write_failed, inspect(exception)}}
      after
        File.rm(tmp_path)
      end
    end
  end

  defp tmp_path(full_path) do
    Path.join(
      Path.dirname(full_path),
      "." <>
        Path.basename(full_path) <>
        ".multipatch-" <> Integer.to_string(System.unique_integer([:positive]))
    )
  end

  # Best-effort restore of files written so far within this transaction.
  defp rollback_written(written) do
    for w <- written do
      if w.file_existed? do
        File.write(w.full_path, w.original_content)
      else
        File.rm(w.full_path)
      end
    end

    :ok
  end

  defp normalize_patch_spec(map) do
    path = Map.get(map, :path) || Map.get(map, "path")

    target =
      Map.get(map, :target) ||
        Map.get(map, "target") ||
        Map.get(map, :target_content) ||
        Map.get(map, "target_content") ||
        ""

    replacement =
      Map.get(map, :replacement) ||
        Map.get(map, "replacement") ||
        Map.get(map, :replacement_content) ||
        Map.get(map, "replacement_content") ||
        ""

    tier =
      case Map.get(map, :tier) || Map.get(map, "tier") do
        :ast -> :ast
        "ast" -> :ast
        :exact -> :exact
        "exact" -> :exact
        :fuzzy -> :fuzzy
        "fuzzy" -> :fuzzy
        _ -> :auto
      end

    allow_multiple =
      Map.get(map, :allow_multiple, false) == true or
        Map.get(map, "allow_multiple", false) == true

    %{
      path: path,
      target: target,
      replacement: replacement,
      tier: tier,
      allow_multiple: allow_multiple
    }
  end

  defp resolve_file_path(project_root, path) do
    WorkspacePath.resolve(project_root, path)
  end
end
