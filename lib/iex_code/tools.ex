defmodule IexCode.Tools do
  @moduledoc """
  Core tool execution engine for agents in IexCode.
  All tools are executed safely in the context of the active workspace project.
  """
  require Logger

  alias IexCode.{Outputs, Projects, Runs}
  alias IexCode.Projects.Project
  alias IexCode.Research.{Fetcher, Search}
  alias IexCode.Sessions
  alias IexCode.Settings

  alias IexCode.Tools.{
    ASTSearch,
    BoundedFiles,
    Git,
    MultiPatch,
    NativeCommand,
    TerminalServer,
    TestRunner
  }

  alias IexCode.Tools.MultiPatch.Snapshot
  alias IexCode.WorkspacePath

  @doc """
  Returns tool specifications formatted for Anthropic and OpenAI tool calls.
  """
  def tool_definitions(allowlist \\ :all) do
    definitions = [
      %{
        name: "read_file",
        description:
          "Read a bounded, line-numbered page from a workspace file. At most 800 lines or 1 MiB are returned; use start_line/end_line to continue when the response says it was truncated.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Relative or absolute path to the file"},
            start_line: %{type: "integer", description: "Optional 1-indexed start line"},
            end_line: %{
              type: "integer",
              description: "Optional 1-indexed end line (each response is still bounded)"
            },
            scan_offset: %{
              type: "integer",
              minimum: 0,
              description:
                "Continuation byte offset returned when scanning to a distant start_line pauses"
            },
            scan_start_line: %{
              type: "integer",
              minimum: 1,
              description:
                "Continuation line number returned with scan_offset; preserve the original start_line"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "read_output_artifact",
        description:
          "Read one bounded chunk from a previously returned command or test output artifact.",
        parameters: %{
          type: "object",
          properties: %{
            artifact_id: %{type: "string", description: "Opaque output artifact ID"},
            offset: %{
              type: "integer",
              minimum: 0,
              description: "Byte offset to start reading at (default 0)"
            },
            length: %{
              type: "integer",
              minimum: 1,
              maximum: 65_536,
              description: "Maximum bytes to read (default and maximum 65536)"
            }
          },
          required: ["artifact_id"]
        }
      },
      %{
        name: "write_file",
        description: "Write or create a file in the workspace.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path to write"},
            content: %{type: "string", description: "Complete content to write"}
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "patch_file",
        description: "Replace exact target content inside a file with replacement content.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path to modify"},
            target_content: %{type: "string", description: "Exact string in the file to replace"},
            replacement_content: %{type: "string", description: "Replacement content string"}
          },
          required: ["path", "target_content", "replacement_content"]
        }
      },
      %{
        name: "multi_patch",
        description:
          "Atomically apply multiple code patches across one or more files with 3-tier matching (AST, exact, fuzzy) and automatic rollback on failure.",
        parameters: %{
          type: "object",
          properties: %{
            patches: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  path: %{type: "string", description: "Relative file path"},
                  target_content: %{type: "string", description: "Target code to replace"},
                  replacement_content: %{type: "string", description: "Replacement code"}
                },
                required: ["path", "target_content", "replacement_content"]
              },
              description: "List of patch objects to apply atomically"
            }
          },
          required: ["patches"]
        }
      },
      %{
        name: "ast_search",
        description:
          "Search Elixir AST symbols (modules, functions, specs, docs, attributes) across workspace.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Symbol name or search string"},
            type: %{
              type: "string",
              enum: [
                "all",
                "module",
                "function",
                "macro",
                "spec",
                "doc",
                "attribute",
                "type",
                "callback"
              ],
              description: "Symbol type filter"
            },
            path: %{type: "string", description: "Optional subpath to search within"},
            arity: %{type: "integer", description: "Optional function arity filter"},
            line: %{type: "integer", description: "Optional target line number"}
          },
          required: ["query"]
        }
      },
      %{
        name: "run_tests",
        description:
          "Run mix test suite or specific test file with structured failure diagnostics.",
        parameters: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional test files or paths to run"
            },
            line: %{
              type: "integer",
              description: "Optional line number when running a single test file"
            },
            failed: %{type: "boolean", description: "Run only previously failed tests"},
            seed: %{type: "integer", description: "Seed for test execution"},
            timeout_ms: %{type: "integer", description: "Timeout in milliseconds (default 60000)"}
          }
        }
      },
      %{
        name: "git_status",
        description: "Get structured Git status (branch, staged, unstaged, untracked files).",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Optional repo directory path"}
          }
        }
      },
      %{
        name: "git_diff",
        description: "Get Git diff of working tree or staged changes.",
        parameters: %{
          type: "object",
          properties: %{
            staged: %{type: "boolean", description: "Whether to return staged diff (--cached)"},
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional paths filter"
            }
          }
        }
      },
      %{
        name: "git_stage",
        description: "Stage files for Git commit.",
        parameters: %{
          type: "object",
          properties: %{
            files: %{
              type: "array",
              items: %{type: "string"},
              description: "List of file paths to stage (or '.' for all)"
            }
          },
          required: ["files"]
        }
      },
      %{
        name: "git_commit",
        description: "Commit staged changes with a commit message.",
        parameters: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Commit message"},
            allow_empty: %{type: "boolean", description: "Allow empty commit"}
          },
          required: ["message"]
        }
      },
      %{
        name: "git_generate_commit",
        description: "Generate a conventional semantic commit message from staged changes.",
        parameters: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "list_dir",
        description:
          "List a bounded page of directory contents including files and subdirectories.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Directory path relative to workspace or absolute"
            },
            recursive: %{type: "boolean", description: "Whether to list recursively"},
            offset: %{type: "integer", minimum: 0, description: "Entry offset for pagination"},
            limit: %{
              type: "integer",
              minimum: 1,
              maximum: 200,
              description: "Entries to return (default and maximum 200)"
            }
          }
        }
      },
      %{
        name: "grep_search",
        description:
          "Search for regex or text query patterns across project files with bounded file and match scanning.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Text or regex pattern to search for"},
            path: %{type: "string", description: "Subdirectory or file to search in"},
            case_sensitive: %{type: "boolean", description: "Whether search is case-sensitive"},
            offset: %{
              type: "integer",
              minimum: 0,
              description: "Eligible-file offset for continuing a truncated search"
            }
          },
          required: ["query"]
        }
      },
      %{
        name: "run_command",
        description: "Execute a terminal / shell command in the project directory.",
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", description: "Shell command line to execute"},
            timeout_ms: %{type: "integer", description: "Timeout in milliseconds (default 30000)"}
          },
          required: ["command"]
        }
      },
      %{
        name: "web_search",
        description:
          "Federated public web search with normalized titles, URLs, snippets, providers, and citation-ready source identifiers.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Search query"},
            providers: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Optional configured ranked-search providers (Tavily, Brave, Exa, Perplexity, Firecrawl, Linkup, Serper, SerpApi, Google, Bing, SearxNG, DuckDuckGo)"
            },
            max_results: %{
              type: "integer",
              description: "Maximum normalized results to return (1-50)"
            }
          },
          required: ["query"]
        }
      },
      %{
        name: "fetch_url",
        description:
          "Fetch readable text from a public HTTP(S) source with DNS, redirect, MIME, timeout, and response-size safety checks.",
        parameters: %{
          type: "object",
          properties: %{
            url: %{type: "string", description: "Public HTTP(S) URL to fetch"}
          },
          required: ["url"]
        }
      }
    ]

    filter_tool_definitions(definitions, allowlist)
  end

  # --- Direct Delegations ---
  def ast_search(query, root_path \\ "."), do: ASTSearch.search(root_path, query)

  def multi_patch(patches, root_path \\ ".", opts \\ []) do
    args = Map.put(trusted_lock_args(opts), "patches", patches)

    with_mutation_locks("multi_patch", args, root_path, fn ->
      MultiPatch.apply_patches(root_path, patches, opts)
    end)
  end

  def run_tests(opts \\ []) do
    root_path = Keyword.get(opts, :project_root, File.cwd!())
    args = Map.put(trusted_lock_args(opts), "operation_id", Keyword.get(opts, :operation_id))

    with_mutation_locks("run_tests", args, root_path, fn identity_opts ->
      scoped_opts =
        opts
        |> Keyword.put(:run_id, Keyword.get(identity_opts, :run_id))
        |> Keyword.put(:session_id, Keyword.get(identity_opts, :session_id))
        |> Keyword.put(:operation_id, trusted_operation_id(args, identity_opts))

      TestRunner.run(scoped_opts)
    end)
  end

  def git_status(repo_dir \\ "."), do: Git.status(repo_dir)

  def git_diff(repo_dir \\ ".", opts \\ []) do
    preview_limit = Keyword.get(opts, :max_bytes, 8 * 1_024 * 1_024)

    case Git.diff_bounded(repo_dir, Keyword.put(opts, :max_bytes, preview_limit)) do
      {:ok, %{content: output, truncated?: false}} ->
        {:ok, output}

      {:ok, %{content: output, truncated?: true}} ->
        {:ok, output <> "\n\n[diff preview truncated at #{preview_limit} bytes]"}

      {:error, _reason} = error ->
        error
    end
  end

  def git_stage(files, repo_dir \\ ".", opts \\ []) do
    args = Map.put(trusted_lock_args(opts), "files", files)

    with_mutation_locks("git_stage", args, repo_dir, fn ->
      Git.stage(files, repo_dir)
    end)
  end

  def git_commit(message, repo_dir \\ ".", opts \\ []) do
    args = Map.put(trusted_lock_args(opts), "message", message)

    with_mutation_locks("git_commit", args, repo_dir, fn ->
      Git.commit(message, repo_dir, opts)
    end)
  end

  def rollback_multi_patch(transaction_id, project_root, opts \\ []) do
    case Snapshot.get_snapshot(transaction_id) do
      {:ok, %{patches: patches} = snapshot} ->
        # Lock planning needs paths only. Keep the one hydrated manifest as the
        # sole body-bearing value while the rollback runs.
        path_refs = Enum.map(patches, &%{"path" => &1.path})
        args = Map.put(trusted_lock_args(opts), "patches", path_refs)

        with_mutation_locks("multi_patch", args, project_root, fn ->
          MultiPatch.rollback_snapshot(transaction_id, snapshot)
        end)

      _missing_or_invalid ->
        MultiPatch.rollback(transaction_id)
    end
  end

  def git_generate_commit(repo_dir \\ "."), do: Git.generate_commit_message(repo_dir)

  @doc """
  Executes a named tool with arguments inside the workspace `root_path`.
  Implementation crashes are contained and returned as `{:error, reason}`
  instead of propagating to callers.
  """
  def execute(tool_name, args, root_path, on_progress \\ fn _p, _msg -> :ok end) do
    with {:ok, args} <- prepare_trusted_tool_args(tool_name, args, root_path) do
      with_mutation_locks(tool_name, args, root_path, fn identity_opts, remaining_timeout_ms ->
        trusted_args =
          args
          |> Map.put("__workspace_lock_identity__", identity_opts)
          |> put_remaining_command_timeout(tool_name, remaining_timeout_ms)

        do_execute(tool_name, trusted_args, root_path, on_progress)
      end)
    end
  rescue
    exception -> {:error, "Tool #{tool_name} crashed: #{Exception.message(exception)}"}
  end

  defp do_execute("read_file", %{"path" => path} = args, root_path, on_progress) do
    on_progress.(10, "Resolving path: #{path}")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        if File.regular?(full_path) do
          on_progress.(50, "Reading file bytes...")

          opts = [
            start_line: Map.get(args, "start_line"),
            end_line: Map.get(args, "end_line"),
            scan_offset: Map.get(args, "scan_offset"),
            scan_start_line: Map.get(args, "scan_start_line")
          ]

          case BoundedFiles.read_range(full_path, opts) do
            {:ok, page} ->
              on_progress.(100, "Read complete (#{page.lines_read} lines)")
              content = IexCode.Sessions.sanitize_utf8(page.content)

              notice =
                cond do
                  page.scan_limited? ->
                    "\n... [scan paused after #{page.scan_limit} bytes before reaching the requested range; " <>
                      "continue with the same start_line/end_line plus scan_offset=#{page.next_scan_offset} " <>
                      "and scan_start_line=#{page.next_scan_start_line}]"

                  page.byte_truncated? ->
                    "\n... [truncated at #{page.byte_limit} bytes inside line #{page.last_line}; " <>
                      "the line is too large for an agent response—narrow the file with grep_search or a command]"

                  page.truncated? and is_integer(page.next_line) ->
                    "\n... [truncated after #{page.lines_read} lines; continue with start_line=#{page.next_line}]"

                  true ->
                    ""
                end

              {:ok, content <> notice}

            {:error, :invalid_line_range} ->
              {:error,
               "Invalid line range or continuation: start_line must be >= 1, end_line must be >= start_line, scan_offset >= 0, and scan_start_line must be between 1 and start_line"}

            {:error, reason} ->
              {:error, "Failed to read file #{path}: #{inspect(reason)}"}
          end
        else
          {:error, "File does not exist: #{path}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{path}"}
    end
  end

  defp do_execute(
         "read_output_artifact",
         %{"artifact_id" => artifact_id} = args,
         _root_path,
         on_progress
       ) do
    offset = Map.get(args, "offset", 0)
    length = Map.get(args, "length", 65_536)

    scope = %{
      session_id: arg_value(args, "session_id"),
      run_id: arg_value(args, "run_id"),
      operation_id: arg_value(args, "operation_id") || arg_value(args, "op_id")
    }

    on_progress.(25, "Reading bounded output artifact chunk...")

    case Outputs.fetch_chunk(artifact_id, scope, offset, length) do
      {:ok, %{artifact: artifact, data: data, next_offset: next_offset, eof: eof}} ->
        on_progress.(100, "Output artifact chunk retrieved")
        safe_data = sanitize_artifact_chunk(data, length)
        safe_name = sanitize_artifact_label(artifact.name)

        {:ok,
         "Artifact: #{artifact.id}\nName: #{safe_name}\nStatus: #{artifact.status}\n" <>
           "Offset: #{offset}\nNext offset: #{next_offset}\nEOF: #{eof}\n\n#{safe_data}"}

      {:error, :scope_required} ->
        {:error, "Output artifact access requires a trusted session, run, or operation scope"}

      {:error, :invalid_range} ->
        {:error, "Invalid artifact byte range; offset must be >= 0 and length must be 1..65536"}

      {:error, _not_available} ->
        {:error, "Output artifact is unavailable in this session or run"}
    end
  end

  defp do_execute("write_file", %{"path" => path, "content" => content}, root_path, on_progress) do
    on_progress.(20, "Creating parent directories for #{path}...")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        File.mkdir_p!(Path.dirname(full_path))

        on_progress.(70, "Writing #{byte_size(content)} bytes to file...")

        case atomic_write(full_path, content) do
          :ok ->
            on_progress.(100, "File written successfully: #{path}")
            {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}

          {:error, reason} ->
            {:error, "Failed to write file #{path}: #{inspect(reason)}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{path}"}
    end
  end

  defp do_execute(
         "patch_file",
         %{"path" => path, "target_content" => target, "replacement_content" => replacement},
         root_path,
         on_progress
       ) do
    on_progress.(20, "Reading target file #{path}...")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        if File.exists?(full_path) do
          content = File.read!(full_path)

          case MultiPatch.patch_string(content, target, replacement) do
            {:ok, %{content: new_content}} ->
              on_progress.(60, "Replacing target content...")

              case atomic_write(full_path, new_content) do
                :ok ->
                  on_progress.(100, "Patched #{path} successfully")
                  {:ok, "Successfully patched #{path}"}

                {:error, reason} ->
                  {:error, "Failed to write patched file #{path}: #{inspect(reason)}"}
              end

            {:error, :not_found} ->
              {:error, "Target content not found in #{path}"}
          end
        else
          {:error, "File does not exist: #{path}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{path}"}
    end
  end

  defp do_execute("multi_patch", %{"patches" => patches} = args, root_path, on_progress) do
    on_progress.(20, "Applying #{length(patches)} patches atomically...")

    case MultiPatch.apply_patches(root_path, patches,
           session_id: Map.get(args, "session_id"),
           run_id: Map.get(args, "run_id")
         ) do
      {:ok, summary} ->
        on_progress.(100, "Applied #{summary.applied} patches successfully")

        msg =
          "Applied #{summary.applied} patches (AST: #{summary.tiers_used.ast}, Exact: #{summary.tiers_used.exact}, Fuzzy: #{summary.tiers_used.fuzzy}).\n\n#{summary.diff}"

        {:ok, msg}

      {:error, reason} ->
        {:error, "MultiPatch failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("ast_search", args, root_path, on_progress) do
    requested_path = Map.get(args, "path", "") || ""

    case resolve_path(root_path, requested_path) do
      {:ok, search_path} ->
        on_progress.(30, "Scanning AST symbols in #{search_path}...")

        # ASTSearch is also a reusable local API and intentionally accepts an
        # absolute scope. The model-facing tool gateway must not pass that
        # capability through: resolve it against the selected workspace first.
        # Remove `path` from the query after using it as the scan root because
        # Query also treats that field as a relative result-path filter.
        confined_args = args |> Map.delete("path") |> Map.delete(:path)

        case ASTSearch.search_with_metadata(search_path, confined_args) do
          {:ok, metadata} ->
            results = metadata.results
            on_progress.(100, "Found #{length(results)} matching symbols")
            formatted = ASTSearch.format_results(results, include_code: true)

            notice =
              if metadata.truncated? do
                reasons = Enum.join(metadata.truncation_reasons, ", ")

                "\n... [AST search truncated: #{reasons}; scanned #{metadata.scanned_files} files " <>
                  "and #{metadata.scanned_bytes} bytes. Narrow query/path for omitted symbols]"
              else
                ""
              end

            {:ok, formatted <> notice}

          {:error, reason} ->
            {:error, "AST search failed: #{inspect(reason)}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{requested_path}"}
    end
  end

  defp do_execute("run_tests", args, root_path, on_progress) do
    lock_identity = Map.get(args, "__workspace_lock_identity__", [])

    opts =
      [project_root: root_path, on_progress: on_progress]
      |> add_opt_from_map(args, "paths", :paths)
      |> add_opt_from_map(args, "line", :line)
      |> add_opt_from_map(args, "failed", :failed)
      |> add_opt_from_map(args, "seed", :seed)
      |> add_opt_from_map(args, "timeout_ms", :timeout_ms)
      |> Keyword.put(:run_id, Keyword.get(lock_identity, :run_id))
      |> Keyword.put(:session_id, Keyword.get(lock_identity, :session_id))
      |> Keyword.put(:operation_id, trusted_operation_id(args, lock_identity))

    case TestRunner.run(opts) do
      {:ok, %{status: :passed} = res} ->
        {:ok,
         "Tests PASSED: #{res.total} tests (#{res.duration_s}s)\nOutput artifact: #{res.artifact_id}"}

      {:ok, %{status: :failed} = res} ->
        failures_summary =
          res.failures
          |> Enum.map(fn f ->
            code_line = if f.code_snippet, do: "\n    code: #{f.code_snippet}", else: ""
            "  * #{f.file}:#{f.line} - #{f.test_name} (#{f.module})\n    #{f.message}#{code_line}"
          end)
          |> Enum.join("\n")

        {:ok,
         "Tests FAILED: #{res.failures_count}/#{res.total} failures:\n#{failures_summary}\n\nOutput preview:\n#{res.raw_output}\n\nOutput artifact: #{res.artifact_id}"}

      {:ok, %{status: :compilation_error} = res} ->
        errs =
          res.compilation_errors
          |> Enum.map(fn e -> "  * #{e.file}:#{e.line} [#{e.error_type}] #{e.message}" end)
          |> Enum.join("\n")

        {:error,
         "Compilation errors before test run:\n#{errs}\nOutput artifact: #{res.artifact_id}"}

      {:ok, %{status: status} = res} ->
        {:ok,
         "Tests completed with status #{status}:\n#{res.raw_output}\n\nOutput artifact: #{res.artifact_id}"}

      {:error, {:output_limit_exceeded, artifact_id}} ->
        {:error,
         "Test run stopped: output_limit_exceeded. Captured output artifact: #{artifact_id}"}

      {:error, reason} ->
        {:error, "Test run failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_status", args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""

    case resolve_path(root_path, sub_path) do
      {:ok, repo_dir} ->
        on_progress.(30, "Checking git status for #{repo_dir}...")

        case Git.status(repo_dir, path_limit: 300, output_limit_bytes: 512 * 1_024) do
          {:ok, status_res} ->
            on_progress.(100, "Git status retrieved")

            staged_list =
              Enum.map_join(status_res.staged, "\n  ", fn s -> "#{s.status}: #{s.path}" end)

            unstaged_list =
              Enum.map_join(status_res.unstaged, "\n  ", fn s -> "#{s.status}: #{s.path}" end)

            untracked_list = Enum.map_join(status_res.untracked, "\n  ", & &1)

            msg =
              """
              Branch: #{status_res.branch} (clean: #{status_res.clean?})
              Staged retained (#{length(status_res.staged)}):
                #{if staged_list == "", do: "(none)", else: staged_list}
              Unstaged retained (#{length(status_res.unstaged)}):
                #{if unstaged_list == "", do: "(none)", else: unstaged_list}
              Untracked retained (#{length(status_res.untracked)}):
                #{if untracked_list == "", do: "(none)", else: untracked_list}
              """
              |> String.trim()

            notice =
              if status_res.truncated? do
                "\n\n[git status truncated after retaining #{status_res.retained_paths} paths " <>
                  "(path limit #{status_res.path_limit}, producer limit #{status_res.producer_limit_bytes} bytes). " <>
                  "Use run_command with `git status --short -- <path>` to inspect a narrower area.]"
              else
                ""
              end

            {:ok, msg <> notice}

          {:error, reason} ->
            {:error, "Git status failed: #{inspect(reason)}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{sub_path}"}
    end
  end

  defp do_execute("git_diff", args, root_path, on_progress) do
    staged? = Map.get(args, "staged", false) == true
    paths = Map.get(args, "paths", [])
    on_progress.(30, "Fetching diff (staged: #{staged?})...")

    case Git.diff_bounded(root_path, staged: staged?, paths: paths, max_bytes: 2 * 1_024 * 1_024) do
      {:ok, %{content: diff_text, bytes: bytes, truncated?: truncated?}} ->
        on_progress.(100, "Diff fetched (#{bytes} bytes)")

        output =
          cond do
            diff_text == "" -> "(No changes)"
            truncated? -> diff_text <> "\n\n[diff preview truncated at 2 MiB]"
            true -> diff_text
          end

        {:ok, output}

      {:error, reason} ->
        {:error, "Git diff failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_stage", %{"files" => files}, root_path, on_progress) do
    on_progress.(30, "Staging files: #{inspect(files)}...")

    case Git.stage(files, root_path) do
      :ok ->
        on_progress.(100, "Staged files successfully")
        {:ok, "Staged #{inspect(files)} successfully"}

      {:error, reason} ->
        {:error, "Git stage failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_commit", %{"message" => message} = args, root_path, on_progress) do
    allow_empty = Map.get(args, "allow_empty", false) == true
    on_progress.(30, "Creating commit with message: #{message}...")

    case Git.commit(message, root_path, allow_empty: allow_empty) do
      {:ok, commit_res} ->
        on_progress.(100, "Created commit #{commit_res.short_hash}")
        {:ok, "Created commit #{commit_res.short_hash}: #{commit_res.message}"}

      {:error, :nothing_staged} ->
        {:error, "Nothing staged to commit (use allow_empty: true if intentional)"}

      {:error, reason} ->
        {:error, "Git commit failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_generate_commit", _args, root_path, on_progress) do
    on_progress.(30, "Analyzing changes to generate semantic commit...")

    case Git.generate_commit_message(root_path) do
      {:ok, msg} ->
        on_progress.(100, "Generated commit message")
        {:ok, msg}

      {:error, reason} ->
        {:error, "Git generate commit failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("list_dir", args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""
    on_progress.(30, "Listing #{sub_path}...")

    case resolve_path(root_path, sub_path) do
      {:ok, full_path} ->
        if File.dir?(full_path) do
          recursive? = Map.get(args, "recursive", false) == true

          offset = Map.get(args, "offset", 0)
          limit = Map.get(args, "limit", if(recursive?, do: 200, else: 150))

          {:ok, page} =
            BoundedFiles.list(full_path, recursive: recursive?, offset: offset, limit: limit)

          on_progress.(100, "Listed #{length(page.entries)} items")

          notice =
            if page.truncated? and is_integer(page.next_offset) do
              "\n... [listing truncated; continue with offset=#{page.next_offset} and limit=#{page.limit}]"
            else
              ""
            end

          {:ok, Enum.join(page.entries, "\n") <> notice}
        else
          {:error, "Not a directory: #{sub_path}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{sub_path}"}
    end
  end

  defp do_execute("grep_search", %{"query" => query} = args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""
    case_sensitive? = Map.get(args, "case_sensitive", false)

    case resolve_path(root_path, sub_path) do
      {:ok, search_dir} ->
        on_progress.(30, "Scanning files in #{search_dir} for query '#{query}'...")

        {:ok, page} =
          BoundedFiles.grep(search_dir, root_path, query,
            case_sensitive: case_sensitive?,
            offset: Map.get(args, "offset", 0)
          )

        on_progress.(100, "Found #{length(page.matches)} matches")

        content =
          if page.matches == [],
            do: "No matches found for '#{query}'",
            else: Enum.join(page.matches, "\n")

        notice =
          if page.truncated? do
            continuation =
              if is_integer(page.next_offset),
                do: " Continue with offset=#{page.next_offset}.",
                else: ""

            "\n... [search truncated by bounded file, byte, line, or match limits.#{continuation} Narrow query/path for omitted matches]"
          else
            ""
          end

        {:ok, content <> notice}

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{sub_path}"}
    end
  end

  defp do_execute("run_command", args, root_path, on_progress) do
    command = Map.get(args, "command") || Map.get(args, :command)
    session_id = Map.get(args, "session_id") || Map.get(args, :session_id)
    timeout = Map.get(args, "timeout_ms") || Map.get(args, :timeout_ms) || 30_000
    requested_timeout = Map.get(args, "__requested_timeout_ms__", timeout)
    agent_name = Map.get(args, "agent_name") || Map.get(args, :agent_name) || "Agent"
    op_id = Map.get(args, "op_id") || Map.get(args, :op_id)

    if session_id && session_id != "" do
      on_progress.(20, "Executing agent command in terminal: #{command}")
      output_artifacts_config = Application.get_env(:iex_code, :output_artifacts, [])

      case TerminalServer.run_agent_command(session_id, command, agent_name,
             timeout_ms: timeout,
             op_id: op_id,
             workspace_path: root_path,
             workspace_lock_identity: Map.get(args, "__workspace_lock_identity__", []),
             # Artifact policy is trusted application configuration. Tool-call
             # extras must not disable disk spooling and move a large capture
             # back into the BEAM heap.
             output_artifact: Keyword.get(output_artifacts_config, :enabled, true),
             output_artifact_attrs: %{
               run_id: Keyword.get(Map.get(args, "__workspace_lock_identity__", []), :run_id),
               session_id:
                 Keyword.get(Map.get(args, "__workspace_lock_identity__", []), :session_id),
               operation_id:
                 trusted_operation_id(
                   args,
                   Map.get(args, "__workspace_lock_identity__", [])
                 )
             }
           ) do
        {:ok, %{exit_code: 0, output: output}} ->
          on_progress.(100, "Command exited successfully (0)")
          {:ok, output}

        {:ok, %{exit_code: exit_code, output: output}} ->
          on_progress.(100, "Command failed (code #{exit_code})")
          {:ok, "Exit Code #{exit_code}:\n#{output}"}

        {:error, :timeout} ->
          on_progress.(100, "Command timed out after #{requested_timeout}ms")
          {:error, "Command timed out after #{requested_timeout}ms"}

        {:error, reason} ->
          on_progress.(100, "Command failed: #{inspect(reason)}")
          {:error, "Command failed: #{inspect(reason)}"}
      end
    else
      on_progress.(20, "Starting command: #{command} in #{root_path}")

      lock_identity = Map.get(args, "__workspace_lock_identity__", [])
      output_artifacts_config = Application.get_env(:iex_code, :output_artifacts, [])

      native_opts = [
        timeout_ms: timeout,
        run_id: Keyword.get(lock_identity, :run_id),
        session_id: Keyword.get(lock_identity, :session_id),
        operation_id: trusted_operation_id(args, lock_identity),
        resource_run_key: Map.get(args, "run_id") || Map.get(args, :run_id) || op_id,
        resource_priority: :background,
        output_limit_bytes:
          Keyword.get(output_artifacts_config, :artifact_limit_bytes, 256 * 1_048_576),
        output_artifact: Keyword.get(output_artifacts_config, :enabled, true),
        output_options: []
      ]

      case NativeCommand.run(command, root_path, native_opts) do
        {:ok, %{exit_code: exit_code, output: output}} ->
          output = IexCode.Sessions.sanitize_utf8(output)

          if exit_code == 0 do
            on_progress.(100, "Command exited successfully (0)")
            {:ok, output}
          else
            on_progress.(100, "Command failed (code #{exit_code})")
            {:ok, "Exit Code #{exit_code}:\n#{output}"}
          end

        {:error, {:output_limit_exceeded, artifact_id}} ->
          on_progress.(100, "Command stopped: output limit exceeded")
          {:error, "output_limit_exceeded (artifact #{artifact_id})"}

        {:error, {:timeout, artifact_id, output}} ->
          on_progress.(100, "Command timed out after #{requested_timeout}ms")

          {:error,
           "Command timed out after #{requested_timeout}ms (artifact #{artifact_id}). Partial output:\n#{IexCode.Sessions.sanitize_utf8(output)}"}

        {:error, :timeout} ->
          on_progress.(100, "Command timed out after #{requested_timeout}ms")
          {:error, "Command timed out after #{requested_timeout}ms"}

        {:error, reason} ->
          on_progress.(100, "Command failed: #{inspect(reason)}")
          {:error, "Command failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_execute("web_search", %{"query" => query} = args, _root_path, on_progress) do
    search_config = Settings.search_config()
    requested_providers = Map.get(args, "providers")

    providers =
      if requested_providers in [nil, []], do: search_config.order, else: requested_providers

    max_results = args |> Map.get("max_results", 10) |> normalize_search_limit()

    on_progress.(15, "Searching #{Enum.join(providers, ", ")}...")

    case Search.search(query,
           providers: providers,
           config: search_config,
           limit: max_results,
           max_concurrency: search_config.parallelism
         ) do
      {:ok, response} ->
        results = Enum.take(response.results, max_results)

        on_progress.(
          100,
          "Found #{length(results)} sources across #{length(response.providers)} providers"
        )

        {:ok, format_search_results(query, results, response.errors)}

      {:error, reason} ->
        {:error, "Federated search failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("fetch_url", %{"url" => url}, _root_path, on_progress) do
    on_progress.(15, "Validating public source URL...")

    case Fetcher.fetch(url) do
      {:ok, fetched} ->
        on_progress.(100, "Fetched #{fetched.bytes} bounded bytes")
        {:ok, "Source: #{fetched.url}\nContent-Type: #{fetched.content_type}\n\n#{fetched.text}"}

      {:error, reason} ->
        {:error, "Public source fetch rejected: #{inspect(reason)}"}
    end
  end

  defp do_execute(unknown_tool, _args, _root_path, _on_progress) do
    {:error, "Unknown tool: #{unknown_tool}"}
  end

  defp resolve_path(root_path, path) do
    case WorkspacePath.resolve(root_path, path) do
      {:ok, full_path} -> {:ok, full_path}
      {:error, _reason} -> {:error, :outside_workspace}
    end
  end

  # All opaque or directly mutating tools enter the durable workspace-lock gateway
  # before they inspect or change native workspace state. Keeping this gate at the
  # semantic tool boundary also covers direct agent calls and ensures MultiPatch
  # declares its complete file set before its planning phase begins.
  defp with_mutation_locks(tool_name, args, root_path, fun)
       when is_function(fun, 0) or is_function(fun, 1) or is_function(fun, 2) do
    case mutation_resources(tool_name, args) do
      [] ->
        invoke_locked_fun(fun, [], nil)

      resources ->
        with {:ok, project_or_root, identity_opts} <-
               resolve_lock_identity(root_path, args) do
          result =
            if wait_for_command_lock?(tool_name, args) do
              with_waiting_command_lock(project_or_root, resources, identity_opts, args, fun)
            else
              IexCode.WorkspaceLocks.with_locks(
                project_or_root,
                resources,
                identity_opts,
                fn -> invoke_with_active_identity(fun, identity_opts, nil) end
              )
            end

          case result do
            {:error, {:conflict, locks}} -> {:error, {:workspace_lock_waiting, locks}}
            result -> result
          end
        end
    end
  end

  defp with_waiting_command_lock(project_or_root, resources, identity_opts, args, fun) do
    timeout_ms = normalize_command_timeout(arg_value(args, "timeout_ms", 30_000))
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case IexCode.WorkspaceLocks.acquire_or_wait(project_or_root, resources, identity_opts) do
      {:ok, handle} -> run_with_command_handle(handle, identity_opts, deadline, fun)
      {:waiting, handle} -> retry_command_lock(handle, identity_opts, deadline, fun)
      {:error, reason} -> {:error, reason}
    end
  end

  # Persisted application callers fail closed immediately so the UI can surface
  # the owning run/session. Legacy PTY callers without a durable project id keep
  # their historical synchronous contract by waiting within their command budget.
  defp wait_for_command_lock?("run_command", args),
    do: is_nil(nonempty_binary(arg_value(args, "project_id")))

  defp wait_for_command_lock?(_tool_name, _args), do: false

  defp retry_command_lock(handle, identity_opts, deadline, fun) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      locks = Map.get(handle, :locks, [])
      _ = IexCode.WorkspaceLocks.release(handle)
      {:error, {:workspace_lock_waiting, locks}}
    else
      receive do
      after
        min(25, remaining) -> :ok
      end

      case IexCode.WorkspaceLocks.retry(handle) do
        {:ok, held_handle} ->
          run_with_command_handle(held_handle, identity_opts, deadline, fun)

        {:waiting, waiting_handle} ->
          retry_command_lock(waiting_handle, identity_opts, deadline, fun)

        {:error, reason} ->
          _ = IexCode.WorkspaceLocks.release(handle)
          {:error, reason}
      end
    end
  end

  defp run_with_command_handle(handle, identity_opts, deadline, fun) do
    try do
      IexCode.WorkspaceLocks.with_delegation(handle, fn ->
        case IexCode.WorkspaceLocks.assert(handle) do
          :ok ->
            remaining = max(deadline - System.monotonic_time(:millisecond), 1)
            invoke_with_active_identity(fun, identity_opts, remaining)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    after
      _ = IexCode.WorkspaceLocks.release(handle)
    end
  end

  defp invoke_with_active_identity(fun, identity_opts, remaining_timeout_ms) do
    active_identity_opts =
      Keyword.put(
        identity_opts,
        :delegation,
        IexCode.WorkspaceLocks.current_delegation()
      )

    invoke_locked_fun(fun, active_identity_opts, remaining_timeout_ms)
  end

  defp invoke_locked_fun(fun, _identity_opts, _remaining_timeout_ms) when is_function(fun, 0),
    do: fun.()

  defp invoke_locked_fun(fun, identity_opts, _remaining_timeout_ms) when is_function(fun, 1),
    do: fun.(identity_opts)

  defp invoke_locked_fun(fun, identity_opts, remaining_timeout_ms) when is_function(fun, 2),
    do: fun.(identity_opts, remaining_timeout_ms)

  defp mutation_resources("write_file", args), do: file_resources(args, ["path"])
  defp mutation_resources("patch_file", args), do: file_resources(args, ["path"])

  defp mutation_resources("multi_patch", args) do
    args
    |> arg_value("patches", [])
    |> List.wrap()
    |> Enum.map(&arg_value(&1, "path"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.map(&{{:file, &1}, :write})
  end

  defp mutation_resources("run_command", _args), do: [{:project, :exclusive}]
  defp mutation_resources("run_tests", _args), do: [{:project, :exclusive}]
  defp mutation_resources("git_stage", _args), do: [{:git, :exclusive}]
  defp mutation_resources("git_commit", _args), do: [{:git, :exclusive}]
  defp mutation_resources(_tool_name, _args), do: []

  defp file_resources(args, keys) do
    keys
    |> Enum.map(&arg_value(args, &1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&{{:file, &1}, :write})
  end

  defp resolve_lock_identity(root_path, args) when is_binary(root_path) and is_map(args) do
    project_id = arg_value(args, "project_id")

    with {:ok, project_or_root, allow_unmanaged?} <-
           resolve_lock_project(project_id, root_path) do
      requested_run_id = nonempty_binary(arg_value(args, "run_id"))
      routing_session_id = nonempty_binary(arg_value(args, "session_id"))

      durable_session_id =
        trusted_lock_session_id(project_or_root, project_id, routing_session_id)

      durable_run_id =
        trusted_lock_run_id(
          project_or_root,
          project_id,
          requested_run_id,
          durable_session_id
        )

      identity_opts =
        [
          owner_id: lock_owner_id(durable_run_id, routing_session_id),
          project_id: if(match?(%Project{}, project_or_root), do: project_or_root.id),
          run_id: durable_run_id,
          session_id: durable_session_id,
          delegation: IexCode.WorkspaceLocks.current_delegation(),
          allow_unmanaged: allow_unmanaged?
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, project_or_root, identity_opts}
    end
  end

  defp resolve_lock_identity(_root_path, _args), do: {:error, :invalid_workspace}

  defp resolve_lock_project(project_id, root_path)
       when is_binary(project_id) and project_id != "" do
    case fetch_project(project_id) do
      %Project{} = project ->
        if same_workspace?(project.root_path, root_path) do
          {:ok, project, false}
        else
          {:error, :project_workspace_mismatch}
        end

      nil ->
        {:error, :invalid_project}
    end
  end

  defp resolve_lock_project(_project_id, root_path), do: {:ok, root_path, true}

  defp fetch_project(project_id) do
    Projects.get_project!(project_id)
  rescue
    _ in [Ecto.NoResultsError, Ecto.Query.CastError] -> nil
  end

  # A terminal routing id is not automatically a durable lock identity. Legacy
  # callers and tests often use arbitrary PTY ids; binding those as a foreign key
  # would reject an otherwise valid native command. Only a caller that supplied a
  # validated project id may attach a persisted session belonging to that project.
  defp trusted_lock_session_id(
         %Project{id: project_id},
         project_id,
         session_id
       )
       when is_binary(session_id) do
    case Sessions.get_session(session_id) do
      %{project_id: ^project_id} -> session_id
      _ -> nil
    end
  end

  defp trusted_lock_session_id(_project_or_root, _project_id, _session_id), do: nil

  defp trusted_lock_run_id(
         %Project{id: project_id},
         project_id,
         run_id,
         session_id
       )
       when is_binary(run_id) and is_binary(session_id) do
    case Runs.get_run(run_id) do
      %{project_id: ^project_id, session_id: ^session_id} -> run_id
      _ -> nil
    end
  rescue
    _ in [Ecto.Query.CastError] -> nil
  end

  defp trusted_lock_run_id(_project_or_root, _project_id, _run_id, _session_id), do: nil

  defp same_workspace?(registered_root, requested_root) do
    with {:ok, canonical_registered} <- WorkspacePath.resolve(registered_root, ""),
         {:ok, canonical_requested} <- WorkspacePath.resolve(requested_root, "") do
      canonical_registered == canonical_requested
    else
      _ -> false
    end
  end

  defp lock_owner_id(run_id, _session_id) when is_binary(run_id), do: "run:#{run_id}"

  defp lock_owner_id(_run_id, session_id) when is_binary(session_id),
    do: "session:#{session_id}:tool:#{unique_lock_owner_suffix()}"

  defp lock_owner_id(_run_id, _session_id) do
    "tool:#{unique_lock_owner_suffix()}"
  end

  defp unique_lock_owner_suffix,
    do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  defp trusted_lock_args(opts) do
    %{
      "project_id" => Keyword.get(opts, :project_id),
      "run_id" => Keyword.get(opts, :run_id),
      "session_id" => Keyword.get(opts, :session_id)
    }
  end

  defp prepare_trusted_tool_args("read_output_artifact", args, root_path) when is_map(args) do
    with {:ok, _project_or_root, identity_opts} <- resolve_lock_identity(root_path, args) do
      operation_id = trusted_operation_id(args, identity_opts)

      trusted_args =
        args
        |> Map.put("session_id", Keyword.get(identity_opts, :session_id))
        |> Map.put("run_id", Keyword.get(identity_opts, :run_id))
        |> Map.put("operation_id", operation_id)
        |> Map.delete("op_id")

      if Enum.any?(["session_id", "run_id", "operation_id"], fn key ->
           is_binary(Map.get(trusted_args, key))
         end) do
        {:ok, trusted_args}
      else
        {:error, "Output artifact access requires a trusted session, run, or operation scope"}
      end
    end
  end

  defp prepare_trusted_tool_args("read_output_artifact", _args, _root_path),
    do: {:error, "Invalid output artifact request"}

  defp prepare_trusted_tool_args(_tool_name, args, _root_path), do: {:ok, args}

  defp arg_value(map, key, default \\ nil)

  defp arg_value(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_existing_atom(key), default)
    end
  end

  defp arg_value(_map, _key, default), do: default

  defp safe_existing_atom("path"), do: :path
  defp safe_existing_atom("patches"), do: :patches
  defp safe_existing_atom("project_id"), do: :project_id
  defp safe_existing_atom("run_id"), do: :run_id
  defp safe_existing_atom("session_id"), do: :session_id
  defp safe_existing_atom("operation_id"), do: :operation_id
  defp safe_existing_atom("op_id"), do: :op_id
  defp safe_existing_atom(_key), do: :__unknown_lock_arg__

  defp nonempty_binary(value) when is_binary(value) and value != "", do: value
  defp nonempty_binary(_value), do: nil

  defp normalize_command_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_command_timeout(_value), do: 30_000

  defp put_remaining_command_timeout(args, "run_command", remaining)
       when is_integer(remaining) and remaining > 0 do
    requested = normalize_command_timeout(arg_value(args, "timeout_ms", 30_000))

    args
    |> Map.put("__requested_timeout_ms__", requested)
    |> Map.put("timeout_ms", remaining)
  end

  defp put_remaining_command_timeout(args, _tool_name, _remaining), do: args

  # Writes content to a temp file next to the target, then renames it into
  # place so readers never observe a partially-written file.
  defp atomic_write(full_path, content) do
    tmp_path = "#{full_path}.tmp#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, full_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp filter_tool_definitions(definitions, :all), do: definitions
  defp filter_tool_definitions(definitions, nil), do: definitions

  defp filter_tool_definitions(definitions, %MapSet{} = allowlist) do
    filter_tool_definitions(definitions, MapSet.to_list(allowlist))
  end

  defp filter_tool_definitions(definitions, allowlist) when is_list(allowlist) do
    allowed = MapSet.new(Enum.map(allowlist, &to_string/1))
    Enum.filter(definitions, &MapSet.member?(allowed, &1.name))
  end

  defp filter_tool_definitions(_definitions, _allowlist), do: []

  defp normalize_search_limit(value) when is_integer(value), do: value |> max(1) |> min(50)

  defp normalize_search_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_search_limit(parsed)
      _ -> 10
    end
  end

  defp normalize_search_limit(_value), do: 10

  defp format_search_results(query, results, errors) do
    sources =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {result, index} ->
        "[#{index}] #{result.title}\nURL: #{result.url}\nProvider: #{result.provider}\nSnippet: #{result.snippet || "(no snippet)"}"
      end)

    provider_notes =
      errors
      |> Enum.map_join("; ", fn {provider, reason} -> "#{provider}=#{inspect(reason)}" end)
      |> then(&if(&1 == "", do: "none", else: &1))

    "Federated search results for #{inspect(query)}\nProvider errors: #{provider_notes}\n\n#{sources}"
    |> IexCode.Sessions.sanitize_utf8()
  end

  defp add_opt_from_map(opts, map, map_key, opt_key) do
    case Map.get(map, map_key) do
      nil -> opts
      val -> Keyword.put(opts, opt_key, val)
    end
  end

  defp trusted_operation_id(args, identity_opts) do
    operation_id = arg_value(args, "operation_id") || arg_value(args, "op_id")
    session_id = Keyword.get(identity_opts, :session_id)

    case Sessions.get_operation(operation_id) do
      %{session_id: ^session_id} when is_binary(session_id) -> operation_id
      _missing_or_foreign -> nil
    end
  rescue
    _error -> nil
  end

  defp sanitize_artifact_chunk(data, max_bytes) do
    data
    |> String.replace_invalid()
    |> truncate_valid_utf8(max_bytes)
  end

  defp sanitize_artifact_label(value) do
    value
    |> to_string()
    |> String.replace_invalid()
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.slice(0, 200)
  end

  defp truncate_valid_utf8(data, max_bytes) when byte_size(data) <= max_bytes, do: data

  defp truncate_valid_utf8(data, max_bytes) do
    data
    |> binary_part(0, max_bytes)
    |> trim_invalid_utf8_suffix()
  end

  defp trim_invalid_utf8_suffix(data) do
    if String.valid?(data),
      do: data,
      else: trim_invalid_utf8_suffix(binary_part(data, 0, byte_size(data) - 1))
  end
end
