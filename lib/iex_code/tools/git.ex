defmodule IexCode.Tools.Git do
  @moduledoc """
  Git porcelain and plumbing integration engine.
  Provides structured status inspection, diff extraction, staging, committing,
  and conventional semantic commit message generation.
  """

  alias IexCode.Tools.Git.{Status, StatusResult, CommitResult, LogEntry, CommitGenerator}

  @git_timeout_ms 30_000
  @lock_retries 4
  @lock_retry_ms 150

  @doc """
  Returns the structured Git status of the repository at `repo_dir`.
  """
  @default_status_path_limit 2_000
  @default_status_output_limit 2 * 1_024 * 1_024

  @spec status(Path.t(), keyword()) :: {:ok, StatusResult.t()} | {:error, term()}
  def status(repo_dir \\ ".", opts \\ []) do
    path_limit = bounded_status_limit(Keyword.get(opts, :path_limit), @default_status_path_limit)

    output_limit =
      bounded_status_output_limit(
        Keyword.get(opts, :output_limit_bytes),
        @default_status_output_limit
      )

    paths = status_paths(Keyword.get(opts, :paths, []))

    case run_status_bounded(repo_dir, output_limit, paths, opts) do
      {:ok, output, producer_truncated?} ->
        output = if producer_truncated?, do: complete_status_lines(output), else: output
        output = String.replace_invalid(output)

        {:ok,
         Status.parse(output,
           path_limit: path_limit,
           producer_limit_bytes: output_limit,
           producer_truncated?: producer_truncated?
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_status_bounded(repo_dir, output_limit, paths, opts) do
    full_path = Path.expand(repo_dir)
    parent_dir = Path.dirname(full_path)
    status_args = ["status", "--porcelain=v1", "-b", "-uall"]
    status_args = if paths == [], do: status_args, else: status_args ++ ["--"] ++ paths

    with git when is_binary(git) <-
           Keyword.get(opts, :_git_executable) || System.find_executable("git") do
      port =
        Port.open({:spawn_executable, git}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          cd: full_path,
          args: status_args,
          env: direct_git_env(parent_dir, opts)
        ])

      # Very small producers can exit before the caller inspects the Port.
      # Keep the PID optional: the exit-status message still lets collection
      # finish, while termination remains safe when there is no live group.
      os_pid = port_os_pid(port)

      collect_status_output(
        port,
        os_pid,
        [],
        0,
        output_limit,
        System.monotonic_time(:millisecond) + git_timeout(opts)
      )
    else
      nil -> {:error, :git_not_found}
    end
  rescue
    error -> {:error, error}
  end

  defp collect_status_output(port, os_pid, chunks, bytes, limit, deadline) do
    remaining_time = deadline - System.monotonic_time(:millisecond)

    if remaining_time <= 0 do
      terminate_git(port, os_pid)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          remaining_bytes = limit - bytes

          if byte_size(data) <= remaining_bytes do
            collect_status_output(
              port,
              os_pid,
              [data | chunks],
              bytes + byte_size(data),
              limit,
              deadline
            )
          else
            accepted =
              if remaining_bytes > 0, do: binary_part(data, 0, remaining_bytes), else: <<>>

            terminate_git(port, os_pid)
            {:ok, IO.iodata_to_binary(Enum.reverse([accepted | chunks])), true}
          end

        {^port, {:exit_status, 0}} ->
          {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), false}

        {^port, {:exit_status, status}} ->
          output =
            chunks
            |> Enum.reverse()
            |> IO.iodata_to_binary()
            |> String.replace_invalid()
            |> String.trim()

          if String.contains?(output, "not a git repository") do
            {:error, :not_a_git_repo}
          else
            {:error,
             {:git_error, status, if(output == "", do: "git status failed", else: output)}}
          end
      after
        remaining_time ->
          terminate_git(port, os_pid)
          {:error, :timeout}
      end
    end
  end

  defp bounded_status_limit(value, _default) when is_integer(value) and value > 0,
    do: min(value, 5_000)

  defp bounded_status_limit(_value, default), do: default

  defp bounded_status_output_limit(value, _default) when is_integer(value) and value > 0,
    do: min(value, 8 * 1_024 * 1_024)

  defp bounded_status_output_limit(_value, default), do: default

  defp status_paths(path) when is_binary(path) and path != "", do: [path]

  defp status_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.take(100)
  end

  defp status_paths(_paths), do: []

  # A producer cap may split a quoted porcelain path. Parse only records that
  # Git completed with a newline; the truncation flag tells callers that more
  # status entries exist.
  defp complete_status_lines(output) do
    case :binary.matches(output, "\n") do
      [] -> ""
      matches -> binary_part(output, 0, elem(List.last(matches), 0) + 1)
    end
  end

  @doc """
  Returns the diff string.

  ## Options
  - `:staged` - Boolean, returns staged diff (`--cached`)
  - `:paths` - List of file paths to filter
  - `:commit` - Revision/commit range (e.g. "HEAD~1")
  - `:unified` - Context line count (default: 3)
  - `:stat` - Boolean, returns diffstat summary
  """
  @spec diff(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def diff(repo_dir \\ ".", opts \\ []) do
    args = ["diff"]

    args =
      if Keyword.get(opts, :staged, false) do
        args ++ ["--cached"]
      else
        args
      end

    args =
      if Keyword.get(opts, :stat, false) do
        args ++ ["--stat"]
      else
        args
      end

    args =
      case Keyword.get(opts, :unified) do
        n when is_integer(n) -> args ++ ["-U#{n}"]
        _ -> args
      end

    args =
      case Keyword.get(opts, :commit) do
        c when is_binary(c) and c != "" -> args ++ [c]
        _ -> args
      end

    paths = Keyword.get(opts, :paths, [])

    args =
      if paths != [] do
        args ++ ["--"] ++ List.wrap(paths)
      else
        args
      end

    run_git(repo_dir, args)
  end

  @doc """
  Reads at most `:max_bytes` of a diff while Git writes the full producer output
  directly to a temporary file. This is intended for interactive previews where
  retaining a repository-sized binary in a LiveView would be unsafe.
  """
  @spec diff_bounded(Path.t(), keyword()) ::
          {:ok, %{content: binary(), bytes: non_neg_integer(), truncated?: boolean()}}
          | {:error, term()}
  def diff_bounded(repo_dir \\ ".", opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_bytes, 2 * 1_024 * 1_024) |> max(1)

    producer_limit =
      opts |> Keyword.get(:producer_limit_bytes, 256 * 1_048_576) |> normalize_diff_limit()

    spool_root = disk_spool_root()
    :ok = File.mkdir_p(spool_root)
    :ok = File.chmod(spool_root, 0o700)

    output_path =
      Path.join(
        spool_root,
        "iex-code-diff-#{System.unique_integer([:positive, :monotonic])}.patch"
      )

    diff_opts = Keyword.drop(opts, [:max_bytes, :producer_limit_bytes])

    try do
      with {:ok, size} <- diff_to_file(repo_dir, output_path, diff_opts, producer_limit),
           {:ok, io} <- File.open(output_path, [:read, :binary]) do
        try do
          content = IO.binread(io, min(size, max_bytes))

          {:ok,
           %{
             content: if(is_binary(content), do: content, else: ""),
             bytes: size,
             truncated?: size > max_bytes
           }}
        after
          File.close(io)
        end
      end
    after
      File.rm(output_path)
    end
  end

  defp diff_to_file(repo_dir, output_path, opts, producer_limit) do
    args = ["--no-pager", "diff", "--no-ext-diff"]
    args = if Keyword.get(opts, :binary, false), do: args ++ ["--binary"], else: args
    args = if Keyword.get(opts, :full_index, false), do: args ++ ["--full-index"], else: args
    args = if Keyword.get(opts, :no_textconv, false), do: args ++ ["--no-textconv"], else: args
    args = if Keyword.get(opts, :staged, false), do: args ++ ["--cached"], else: args

    args =
      case Keyword.get(opts, :unified) do
        n when is_integer(n) -> args ++ ["-U#{n}"]
        _ -> args
      end

    args =
      case Keyword.get(opts, :commit) do
        commit when is_binary(commit) and commit != "" -> args ++ [commit]
        _ -> args
      end

    paths = Keyword.get(opts, :paths, [])
    args = if paths == [], do: args, else: args ++ ["--"] ++ List.wrap(paths)

    with git when is_binary(git) <-
           Keyword.get(opts, :_git_executable) || System.find_executable("git"),
         {:ok, io} <- File.open(output_path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(output_path, 0o600) do
          port =
            Port.open({:spawn_executable, git}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              :hide,
              cd: repo_dir,
              args: args,
              env: direct_git_env(Path.dirname(Path.expand(repo_dir)), opts)
            ])

          os_pid = port_os_pid(port)

          collect_diff_output(
            port,
            os_pid,
            io,
            0,
            producer_limit,
            System.monotonic_time(:millisecond) + git_timeout(opts)
          )
        end
      after
        File.close(io)
      end
    else
      nil -> {:error, :git_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_diff_output(port, os_pid, io, bytes, limit, deadline) do
    remaining_time = deadline - System.monotonic_time(:millisecond)

    if remaining_time <= 0 do
      terminate_git(port, os_pid)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          remaining_bytes = limit - bytes

          cond do
            byte_size(data) <= remaining_bytes ->
              case IO.binwrite(io, data) do
                :ok ->
                  collect_diff_output(
                    port,
                    os_pid,
                    io,
                    bytes + byte_size(data),
                    limit,
                    deadline
                  )

                {:error, reason} ->
                  terminate_git(port, os_pid)
                  {:error, reason}
              end

            true ->
              write_result =
                if remaining_bytes > 0,
                  do: IO.binwrite(io, binary_part(data, 0, remaining_bytes)),
                  else: :ok

              terminate_git(port, os_pid)

              case write_result do
                :ok -> {:error, :output_limit_exceeded}
                {:error, reason} -> {:error, reason}
              end
          end

        {^port, {:exit_status, 0}} ->
          {:ok, bytes}

        {^port, {:exit_status, status}} ->
          {:error, {:git_error, status}}
      after
        remaining_time ->
          terminate_git(port, os_pid)
          {:error, :timeout}
      end
    end
  end

  defp git_timeout(opts) do
    case Keyword.get(opts, :_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, @git_timeout_ms)
      _other -> @git_timeout_ms
    end
  end

  # OTP's Unix port launcher creates the spawned executable as a process-group
  # and session leader. Directly spawning Git therefore keeps the Port OS PID
  # equal to the private PGID without an extra `setsid` process that may fork.
  defp terminate_git(port, os_pid) do
    _ = IexCode.Tools.PTYAdapter.terminate_process_group(os_pid, :sigkill)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  end

  defp normalize_diff_limit(value) when is_integer(value) and value > 0,
    do: min(value, 256 * 1_048_576)

  defp normalize_diff_limit(_value), do: 256 * 1_048_576

  # Production `/tmp` is an intentionally small tmpfs, so repository-sized
  # diffs must not be spooled there and charged to the container's RAM. Keep
  # transient native output beside the persistent SQLite state by default.
  defp disk_spool_root do
    Application.get_env(:iex_code, :disk_spool_root) ||
      case IexCode.Repo.config()[:database] do
        database when is_binary(database) and database not in ["", ":memory:"] ->
          Path.join(Path.dirname(database), "tmp")

        _other ->
          Path.join(File.cwd!(), "tmp")
      end
  end

  @doc """
  Stages one or more files in the repository (`git add`).
  Accepts `(files, repo_dir)`, `(repo_dir, files)`, or `(files, opts)`.
  """
  def stage(arg1, arg2 \\ ".")

  def stage(files, opts) when is_list(opts) and opts != [] and is_tuple(hd(opts)) do
    repo_dir = Keyword.get(opts, :repo_dir, Keyword.get(opts, :cd, "."))
    do_stage(repo_dir, files)
  end

  def stage(files, []) when is_list(files) and files != [] and not is_tuple(hd(files)) do
    do_stage(".", files)
  end

  def stage(arg1, arg2) do
    cond do
      arg1 == :all ->
        do_stage(arg2, :all)

      arg2 == :all ->
        do_stage(arg1, :all)

      is_list(arg1) and is_binary(arg2) ->
        do_stage(arg2, arg1)

      is_binary(arg1) and is_list(arg2) ->
        if Keyword.keyword?(arg2) and arg2 != [] do
          repo_dir = Keyword.get(arg2, :repo_dir, Keyword.get(arg2, :cd, "."))
          do_stage(repo_dir, arg1)
        else
          do_stage(arg1, arg2)
        end

      is_binary(arg1) and is_binary(arg2) ->
        cond do
          File.dir?(arg1) and not File.dir?(arg2) ->
            do_stage(arg1, arg2)

          File.dir?(arg2) and not File.dir?(arg1) ->
            do_stage(arg2, arg1)

          arg2 == "." ->
            do_stage(arg2, arg1)

          true ->
            do_stage(arg2, arg1)
        end

      is_binary(arg1) and arg2 == [] ->
        if File.dir?(arg1) do
          do_stage(arg1, [])
        else
          do_stage(".", arg1)
        end

      arg1 == [] and is_binary(arg2) ->
        do_stage(arg2, [])

      arg1 == [] and arg2 == [] ->
        :ok

      true ->
        {:error, {:invalid_arguments, arg1, arg2}}
    end
  end

  defp do_stage(_repo_dir, []), do: :ok

  defp do_stage(repo_dir, :all) do
    case run_git(repo_dir, ["add", "-A"]) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp do_stage(repo_dir, ".") do
    do_stage(repo_dir, :all)
  end

  defp do_stage(repo_dir, files) when is_list(files) do
    case run_git(repo_dir, ["add", "--"] ++ files) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp do_stage(repo_dir, file) when is_binary(file) do
    do_stage(repo_dir, [file])
  end

  @doc """
  Unstages one or more files from the index (`git restore --staged` or `git reset HEAD`).
  Accepts `(files, repo_dir)`, `(repo_dir, files)`, or `(files, opts)`.
  """
  def unstage(arg1, arg2 \\ ".")

  def unstage(files, opts) when is_list(opts) and opts != [] and is_tuple(hd(opts)) do
    repo_dir = Keyword.get(opts, :repo_dir, Keyword.get(opts, :cd, "."))
    do_unstage(repo_dir, files)
  end

  def unstage(files, []) when is_list(files) and files != [] and not is_tuple(hd(files)) do
    do_unstage(".", files)
  end

  def unstage(arg1, arg2) do
    cond do
      arg1 == :all ->
        do_unstage(arg2, :all)

      arg2 == :all ->
        do_unstage(arg1, :all)

      is_list(arg1) and is_binary(arg2) ->
        do_unstage(arg2, arg1)

      is_binary(arg1) and is_list(arg2) ->
        if Keyword.keyword?(arg2) and arg2 != [] do
          repo_dir = Keyword.get(arg2, :repo_dir, Keyword.get(arg2, :cd, "."))
          do_unstage(repo_dir, arg1)
        else
          do_unstage(arg1, arg2)
        end

      is_binary(arg1) and is_binary(arg2) ->
        cond do
          File.dir?(arg1) and not File.dir?(arg2) ->
            do_unstage(arg1, arg2)

          File.dir?(arg2) and not File.dir?(arg1) ->
            do_unstage(arg2, arg1)

          arg2 == "." ->
            do_unstage(arg2, arg1)

          true ->
            do_unstage(arg2, arg1)
        end

      is_binary(arg1) and arg2 == [] ->
        if File.dir?(arg1) do
          do_unstage(arg1, [])
        else
          do_unstage(".", arg1)
        end

      arg1 == [] and is_binary(arg2) ->
        do_unstage(arg2, [])

      arg1 == [] and arg2 == [] ->
        :ok

      true ->
        {:error, {:invalid_arguments, arg1, arg2}}
    end
  end

  defp do_unstage(_repo_dir, []), do: :ok

  defp do_unstage(repo_dir, :all) do
    case run_git(repo_dir, ["restore", "--staged", "."]) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        # Fallback for older git
        case run_git(repo_dir, ["reset", "HEAD"]) do
          {:ok, _} ->
            :ok

          {:error, reset_err} ->
            # On an unborn branch there is no HEAD to reset against;
            # clear the staged entries from the index instead.
            if unborn?(repo_dir) do
              case run_git(repo_dir, ["rm", "--force", "--cached", "-r", "--quiet", "."]) do
                {:ok, _} -> :ok
                err -> err
              end
            else
              {:error, reset_err}
            end
        end
    end
  end

  defp do_unstage(repo_dir, ".") do
    do_unstage(repo_dir, :all)
  end

  defp do_unstage(repo_dir, file) when is_binary(file) do
    do_unstage(repo_dir, [file])
  end

  defp do_unstage(repo_dir, files) when is_list(files) do
    case run_git(repo_dir, ["restore", "--staged", "--"] ++ files) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        case run_git(repo_dir, ["reset", "HEAD", "--"] ++ files) do
          {:ok, _} ->
            :ok

          {:error, reset_err} ->
            if unborn?(repo_dir) do
              case run_git(repo_dir, ["rm", "--force", "--cached", "--quiet", "--"] ++ files) do
                {:ok, _} -> :ok
                err -> err
              end
            else
              {:error, reset_err}
            end
        end
    end
  end

  # An unborn branch has no HEAD revision yet (fresh `git init`).
  defp unborn?(repo_dir) do
    match?({:error, _}, run_git(repo_dir, ["rev-parse", "--verify", "--quiet", "HEAD"]))
  end

  @doc """
  Creates a commit with the specified message.
  Accepts `(message, repo_dir, opts)` or `(repo_dir, message, opts)`.
  """
  def commit(arg1, arg2 \\ ".", opts \\ [])

  def commit(arg1, arg2, opts) when is_binary(arg1) and is_binary(arg2) and is_list(opts) do
    cond do
      File.dir?(arg2) and not File.dir?(arg1) ->
        do_commit(arg2, arg1, opts)

      File.dir?(arg1) and not File.dir?(arg2) ->
        do_commit(arg1, arg2, opts)

      true ->
        do_commit(arg2, arg1, opts)
    end
  end

  defp do_commit(repo_dir, message, opts) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    with {:ok, status_res} <- status(repo_dir),
         :ok <- verify_staged_changes(repo_dir, status_res, allow_empty) do
      author_args = [
        "-c",
        "user.name=IexCode Agent",
        "-c",
        "user.email=agent@iexcode.local"
      ]

      commit_args =
        if allow_empty do
          author_args ++ ["commit", "--allow-empty", "-m", message]
        else
          author_args ++ ["commit", "-m", message]
        end

      case run_git(repo_dir, commit_args) do
        {:ok, _commit_output} ->
          {:ok, full_hash} = run_git(repo_dir, ["rev-parse", "HEAD"])
          {:ok, short_hash} = run_git(repo_dir, ["rev-parse", "--short", "HEAD"])

          result = %CommitResult{
            commit_hash: String.trim(full_hash),
            short_hash: String.trim(short_hash),
            message: message,
            author: "IexCode Agent <agent@iexcode.local>",
            timestamp: DateTime.utc_now()
          }

          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Closes the TOCTOU gap between the initial status check and the commit by
  # re-verifying staged content right before committing.
  defp verify_staged_changes(_repo_dir, _status_res, true), do: :ok

  defp verify_staged_changes(repo_dir, status_res, false) do
    case run_git(repo_dir, ["diff", "--cached", "--quiet", "--no-ext-diff"]) do
      # Exit code 1 means the index differs from HEAD (there is content).
      {:error, {:git_error, 1, _}} ->
        :ok

      # Exit code 0 means the index matches HEAD (nothing to commit).
      {:ok, _} ->
        {:error, :nothing_staged}

      # Could not determine (notably an unborn HEAD); the bounded status prefix
      # remains a safe fallback without requiring an unbounded name listing.
      {:error, _} ->
        if status_res.staged == [], do: {:error, :nothing_staged}, else: :ok
    end
  end

  @doc """
  Returns recent commit history as a structured list of LogEntry items.
  """
  @spec log(Path.t(), keyword()) :: {:ok, [LogEntry.t()]} | {:error, term()}
  def log(repo_dir \\ ".", opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    delimiter = "---COMMIT-DELIMITER---"
    format = "#{delimiter}%n%H%n%h%n%an%n%ae%n%ad%n%s%n%b"

    case run_git(repo_dir, ["log", "-n", to_string(limit), "--format=#{format}"]) do
      {:ok, output} ->
        entries =
          output
          |> String.split(delimiter)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn chunk ->
            case String.split(chunk, ~r/\r?\n/, parts: 7) do
              [hash, short_h, author, email, date, subject | rest] ->
                body = Enum.join(rest, "\n") |> String.trim()

                %LogEntry{
                  hash: hash,
                  short_hash: short_h,
                  author: author,
                  email: email,
                  date: date,
                  subject: subject,
                  body: body
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns current active branch name.
  """
  @spec current_branch(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def current_branch(repo_dir \\ ".") do
    case run_git(repo_dir, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} -> {:ok, String.trim(branch)}
      err -> err
    end
  end

  @doc """
  Generates a Conventional Semantic Commit message from staged changes or a diff string.
  """
  @spec generate_commit_message(Path.t() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_commit_message(diff_or_repo \\ ".", opts \\ [])

  def generate_commit_message(diff_str, opts)
      when is_binary(diff_str) and
             (binary_part(diff_str, 0, min(10, byte_size(diff_str))) == "diff --git" or
                binary_part(diff_str, 0, min(6, byte_size(diff_str))) == "--- a/") do
    CommitGenerator.generate(diff_str, [], Keyword.put_new(opts, :include_body, true))
  end

  def generate_commit_message(repo_dir, opts) when is_binary(repo_dir) do
    opts = Keyword.put_new(opts, :include_body, true)

    with {:ok, status_res} <- status(repo_dir),
         {:ok, staged_diff} <- diff(repo_dir, staged: true) do
      staged_paths = Enum.map(status_res.staged, & &1.path)

      diff_text =
        if staged_diff != "" do
          staged_diff
        else
          case diff(repo_dir, []) do
            {:ok, working_diff} -> working_diff
            _ -> ""
          end
        end

      CommitGenerator.generate(diff_text, staged_paths ++ status_res.untracked, opts)
    end
  end

  @doc """
  Applies a patch string to the repository using `git apply`.

  ## Options
  - `:cached` - Boolean, applies patch to index (staged) only
  - `:reverse` - Boolean, applies the patch in reverse (discards changes)
  - `:index` - Boolean, applies patch to both index and working tree
  - `:3way` - Boolean, attempts 3-way merge if patch does not apply cleanly
  - `:whitespace` - Option for git apply whitespace handling (e.g. "nowarn", "fix")
  - `:check` - Boolean, checks if patch can be applied without touching index/worktree
  """
  @spec apply_patch(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def apply_patch(repo_dir, patch_content, opts \\ []) when is_binary(patch_content) do
    args = ["apply"]

    args = if Keyword.get(opts, :cached, false), do: args ++ ["--cached"], else: args
    args = if Keyword.get(opts, :reverse, false), do: args ++ ["--reverse"], else: args
    args = if Keyword.get(opts, :index, false), do: args ++ ["--index"], else: args
    args = if Keyword.get(opts, :check, false), do: args ++ ["--check"], else: args

    args =
      case Keyword.get(opts, :context) do
        context when is_integer(context) and context > 0 -> args ++ ["-C#{context}"]
        _ -> args
      end

    args =
      if Keyword.get(opts, :three_way, false) or Keyword.get(opts, :"3way", false),
        do: args ++ ["--3way"],
        else: args

    args =
      case Keyword.get(opts, :whitespace) do
        ws when is_binary(ws) -> args ++ ["--whitespace=#{ws}"]
        _ -> args
      end

    temp_file =
      Path.join(
        System.tmp_dir!(),
        "git_patch_#{System.system_time(:microsecond)}_#{:erlang.unique_integer([:positive])}.patch"
      )

    try do
      File.write!(temp_file, patch_content)
      run_git(repo_dir, args ++ [temp_file], Keyword.take(opts, [:env]))
    after
      File.rm(temp_file)
    end
  end

  @doc """
  Runs an index-mutating callback while holding Git's official `index.lock`.

  The callback's Git subprocesses receive an explicit alternate index. On a
  successful `{:ok, _}` result that alternate is atomically published over the
  official index; failures leave the official index untouched.
  """
  @spec with_index_transaction(Path.t(), (keyword() -> term()), keyword()) :: term()
  def with_index_transaction(repo_dir, fun, opts \\ [])
      when is_binary(repo_dir) and is_function(fun, 1) and is_list(opts) do
    with {:ok, git_dir_output} <- run_git(repo_dir, ["rev-parse", "--git-dir"]),
         git_dir <- Path.expand(String.trim(git_dir_output), repo_dir),
         lock_path <- Path.join(git_dir, "index.lock"),
         {:ok, lock_io} <- File.open(lock_path, [:write, :binary, :exclusive]) do
      index_path = Path.join(git_dir, "index")
      alternate = Path.join(git_dir, "index.iex-code-#{System.unique_integer([:positive])}")
      original = alternate <> ".original"

      try do
        :ok = File.chmod(lock_path, 0o600)

        copy_result =
          if File.regular?(index_path) do
            with :ok <- File.cp(index_path, alternate),
                 :ok <- File.cp(index_path, original) do
              :ok
            end
          else
            File.touch(alternate)
          end

        case copy_result do
          :ok ->
            :ok = File.chmod(alternate, 0o600)
            result = fun.(env: [{"GIT_INDEX_FILE", alternate}])

            case result do
              {:ok, _} = success ->
                with {:ok, alternate_io} <- File.open(alternate, [:read, :binary]),
                     :ok <- :file.sync(alternate_io),
                     :ok <- File.close(alternate_io),
                     :ok <- publish_index(alternate, index_path, opts) do
                  case safely_after_index_publish(success, opts) do
                    {:ok, final_result} ->
                      final_result

                    {:error, reason} ->
                      case restore_index(index_path, original) do
                        :ok ->
                          {:error, {:index_effect_failed, reason}}

                        {:error, rollback_reason} ->
                          {:error, {:index_rollback_failed, reason, rollback_reason}}
                      end
                  end
                else
                  {:error, reason} -> {:error, {:index_publish_failed, reason}}
                end

              _ ->
                result
            end

          {:error, reason} ->
            {:error, {:index_copy_failed, reason}}
        end
      after
        File.close(lock_io)
        File.rm(alternate)
        File.rm(original)
        File.rm(lock_path)
      end
    else
      {:error, :eexist} -> {:error, :git_index_busy}
      {:error, :enoent} -> {:error, :not_a_git_repo}
      {:error, reason} -> {:error, reason}
      error -> error
    end
  end

  defp publish_index(alternate, index_path, opts) do
    case Keyword.get(opts, :_publish_index) do
      fun when is_function(fun, 2) -> fun.(alternate, index_path)
      _ -> File.rename(alternate, index_path)
    end
  end

  defp after_index_publish(success, opts) do
    case Keyword.get(opts, :after_publish) do
      fun when is_function(fun, 1) -> fun.(success)
      _ -> {:ok, success}
    end
  end

  defp safely_after_index_publish(success, opts) do
    try do
      after_index_publish(success, opts)
    rescue
      error -> {:error, {:raised, error.__struct__, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp restore_index(index_path, original) do
    if File.regular?(original), do: File.rename(original, index_path), else: File.rm(index_path)
  end

  @doc """
  Restores/discards changes to specified files in working tree or staged index.
  """
  @spec restore_file(Path.t(), Path.t() | [Path.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def restore_file(repo_dir, files, opts \\ []) do
    file_list = List.wrap(files)
    staged? = Keyword.get(opts, :staged, true)
    worktree? = Keyword.get(opts, :worktree, true)

    case restore_shape_allowed?(repo_dir, file_list, staged?, worktree?) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        do_restore_file(repo_dir, file_list, staged?, worktree?)
    end
  end

  @doc false
  def restore_shape_allowed(repo_dir, files, opts \\ []) do
    restore_shape_allowed?(
      repo_dir,
      List.wrap(files),
      Keyword.get(opts, :staged, true),
      Keyword.get(opts, :worktree, true)
    )
  end

  defp do_restore_file(repo_dir, file_list, staged?, worktree?) do
    cond do
      staged? and worktree? ->
        # Update both destinations from HEAD in one Git process. The former
        # unstage-then-worktree sequence could fail after already mutating the
        # index for added/renamed paths.
        case run_git(
               repo_dir,
               ["restore", "--source=HEAD", "--staged", "--worktree", "--"] ++ file_list
             ) do
          {:ok, _} = res -> res
          {:error, _} -> run_git(repo_dir, ["checkout", "HEAD", "--"] ++ file_list)
        end

      staged? ->
        case unstage(repo_dir, file_list) do
          :ok -> {:ok, "unstaged"}
          error -> error
        end

      worktree? ->
        case run_git(repo_dir, ["restore", "--"] ++ file_list) do
          {:ok, _} = res ->
            res

          {:error, _} ->
            # Fallback for older git
            run_git(repo_dir, ["checkout", "--"] ++ file_list)
        end

      true ->
        {:ok, "unstaged"}
    end
  end

  defp restore_shape_allowed?(_repo_dir, [], _staged?, _worktree?), do: :ok

  defp restore_shape_allowed?(repo_dir, file_list, staged?, worktree?)
       when staged? and is_list(file_list) do
    case status(repo_dir, path_limit: 5_000, output_limit_bytes: 2 * 1_024 * 1_024) do
      {:ok, status} ->
        unsupported? =
          status.truncated? or Enum.any?(status.conflicted, &(&1.path in file_list)) or
            Enum.any?(status.staged, fn entry ->
              (entry.path in file_list or Map.get(entry, :old_path) in file_list) and
                ((worktree? and entry.status in [:added, :renamed, :copied]) or
                   (not worktree? and entry.status in [:renamed, :copied]))
            end) or rename_or_copy_pair_touches?(repo_dir, file_list)

        if unsupported?, do: {:error, :unsupported_git_shape}, else: :ok

      {:error, :not_a_git_repo} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_shape_allowed?(_repo_dir, _file_list, _staged?, _worktree?), do: :ok

  defp rename_or_copy_pair_touches?(repo_dir, file_list) do
    case run_git_bounded(
           repo_dir,
           [
             "diff",
             "--cached",
             "--name-status",
             "-z",
             "-M",
             "-C",
             "--find-copies-harder",
             "HEAD",
             "--"
           ],
           2 * 1_024 * 1_024
         ) do
      {:ok, output} ->
        case name_status_pairs(output) do
          {:ok, pairs} ->
            Enum.any?(pairs, fn {old_path, new_path} ->
              old_path in file_list or new_path in file_list
            end)

          {:error, _} ->
            true
        end

      _ ->
        true
    end
  end

  defp name_status_pairs(""), do: {:ok, []}

  defp name_status_pairs(output) when is_binary(output) do
    fields = String.split(output, <<0>>, trim: false)

    case List.last(fields) do
      "" -> fields |> Enum.drop(-1) |> parse_name_status_fields([])
      _ -> {:error, :malformed_name_status}
    end
  end

  defp parse_name_status_fields([], pairs), do: {:ok, Enum.reverse(pairs)}

  defp parse_name_status_fields([<<prefix, _::binary>>, old_path, new_path | rest], pairs)
       when prefix in [?R, ?C] and old_path != "" and new_path != "" do
    parse_name_status_fields(rest, [{old_path, new_path} | pairs])
  end

  defp parse_name_status_fields([<<prefix, _::binary>>, path | rest], pairs)
       when prefix in [?A, ?D, ?M, ?T, ?U, ?X, ?B] and path != "" do
    parse_name_status_fields(rest, pairs)
  end

  defp parse_name_status_fields(_fields, _pairs), do: {:error, :malformed_name_status}

  @doc """
  Returns a list of local and remote branches for the repository.
  """
  @spec branches(Path.t()) ::
          {:ok,
           [
             %{
               name: String.t(),
               current?: boolean(),
               remote?: boolean(),
               upstream: String.t() | nil
             }
           ]}
          | {:error, term()}
  def branches(repo_dir \\ ".") do
    case run_git(repo_dir, ["branch", "-a", "--format=%(refname:short)|%(HEAD)|%(upstream:short)"]) do
      {:ok, output} ->
        branches =
          output
          |> String.split(~r/\r?\n/)
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.map(fn line ->
            case String.split(line, "|") do
              [name, head_star, upstream] ->
                %{
                  name: name,
                  current?: head_star == "*",
                  remote?: String.starts_with?(name, "origin/"),
                  upstream: if(upstream != "", do: upstream, else: nil)
                }

              [name] ->
                %{name: name, current?: false, remote?: false, upstream: nil}
            end
          end)

        {:ok, branches}

      err ->
        err
    end
  end

  @doc """
  Switches the active Git branch (`git switch` or `git checkout`).
  Options:
    - `:create` (boolean): creates new branch if true (`git checkout -b <name>`)
  """
  @spec switch_branch(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def switch_branch(repo_dir \\ ".", branch_name, opts \\ []) do
    if valid_branch_name?(branch_name) do
      create? = Keyword.get(opts, :create, false)

      args =
        if create?,
          do: ["checkout", "-b", branch_name],
          else: ["switch", "--no-guess", "--", branch_name]

      run_git(repo_dir, args)
    else
      {:error, :invalid_branch_name}
    end
  end

  defp valid_branch_name?(name) when is_binary(name) and name != "" do
    not String.starts_with?(name, "-") and
      not String.contains?(name, ["..", "@{", " ", "~", "^", ":", "?", "*", "[", "\\"]) and
      not String.ends_with?(name, ["/", ".", ".lock"])
  end

  defp valid_branch_name?(_), do: false

  @doc """
  Creates a new branch at the current commit and checks it out.
  """
  @spec create_branch(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_branch(repo_dir \\ ".", branch_name, opts \\ []) do
    switch_branch(repo_dir, branch_name, Keyword.put(opts, :create, true))
  end

  @doc """
  Fetches updates from remotes (`git fetch`).
  """
  @spec fetch(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch(repo_dir \\ ".", opts \\ []) do
    remote = Keyword.get(opts, :remote)
    args = if remote && remote != "", do: ["fetch", remote], else: ["fetch", "--all"]
    run_git(repo_dir, args)
  end

  @doc """
  Pulls latest changes from upstream remote (`git pull`).
  """
  @spec pull(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def pull(repo_dir \\ ".", opts \\ []) do
    args = ["pull"]
    args = if Keyword.get(opts, :rebase, false), do: args ++ ["--rebase"], else: args
    run_git(repo_dir, args)
  end

  # --- Internal Git Invocation ---

  @doc """
  Runs a git command in `repo_dir`, returning `{:ok, stdout}` on success.

  Errors are structured: `{:error, :timeout}` after #{@git_timeout_ms}ms,
  `{:error, :not_a_git_repo}`, or `{:error, {:git_error, exit_code, message}}`
  where `message` comes from stderr (falling back to stdout). Transient
  `.git/index.lock` contention is retried a few times with small delays.
  """
  def run_git(repo_dir, args, opts \\ []) do
    opts = with_process_index_env(opts)
    run_git_with_retries(Path.expand(repo_dir), args, @lock_retries, opts)
  end

  defp with_process_index_env(opts) do
    case {Keyword.get(opts, :env, []), Process.get(:iex_code_git_index_file)} do
      {[], index} when is_binary(index) and index != "" ->
        Keyword.put(opts, :env, [{"GIT_INDEX_FILE", index}])

      _ ->
        opts
    end
  end

  @doc "Runs Git with a producer-side output cap and direct argv invocation."
  @spec run_git_bounded(Path.t(), [String.t()], pos_integer(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def run_git_bounded(repo_dir, args, max_bytes, opts \\ [])
      when is_binary(repo_dir) and is_list(args) and is_integer(max_bytes) and max_bytes > 0 do
    full_path = Path.expand(repo_dir)
    parent_dir = Path.dirname(full_path)

    with true <- Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, <<0>>))),
         git when is_binary(git) <-
           Keyword.get(opts, :_git_executable) || System.find_executable("git") do
      port =
        Port.open({:spawn_executable, git}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          cd: full_path,
          args: args,
          env: direct_git_env(parent_dir, opts)
        ])

      collect_git_bounded(
        port,
        port_os_pid(port),
        [],
        0,
        max_bytes,
        System.monotonic_time(:millisecond) + git_timeout(opts)
      )
    else
      false -> {:error, :invalid_git_arguments}
      nil -> {:error, :git_not_found}
    end
  rescue
    error -> {:error, error}
  end

  defp collect_git_bounded(port, os_pid, chunks, bytes, limit, deadline) do
    remaining_time = deadline - System.monotonic_time(:millisecond)

    if remaining_time <= 0 do
      terminate_git(port, os_pid)
      drain_port(port)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          if byte_size(data) <= limit - bytes do
            collect_git_bounded(
              port,
              os_pid,
              [data | chunks],
              bytes + byte_size(data),
              limit,
              deadline
            )
          else
            terminate_git(port, os_pid)
            drain_port(port)
            {:error, :output_limit_exceeded}
          end

        {^port, {:exit_status, 0}} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {^port, {:exit_status, status}} ->
          {:error, {:git_error, status}}
      after
        remaining_time ->
          terminate_git(port, os_pid)
          drain_port(port)
          {:error, :timeout}
      end
    end
  end

  defp drain_port(port) do
    receive do
      {^port, _message} -> drain_port(port)
    after
      0 -> :ok
    end
  end

  defp direct_git_env(parent_dir, opts) do
    supplied = Keyword.get(opts, :env, [])
    supplied = if supplied == [], do: process_index_env(), else: supplied

    [
      {~c"GIT_CEILING_DIRECTORIES", String.to_charlist(parent_dir)}
      | Enum.map(supplied, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)
    ]
  end

  defp process_index_env do
    case Process.get(:iex_code_git_index_file) do
      index when is_binary(index) and index != "" -> [{"GIT_INDEX_FILE", index}]
      _ -> []
    end
  end

  defp run_git_with_retries(full_path, args, retries, opts) do
    task = Task.async(fn -> exec_git(full_path, args, opts) end)

    result =
      case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end

    case result do
      {:error, {:git_error, _exit_code, message}} = err ->
        if index_locked?(message) and retries > 0 do
          Process.sleep(@lock_retry_ms)
          run_git_with_retries(full_path, args, retries - 1, opts)
        else
          err
        end

      other ->
        other
    end
  end

  defp index_locked?(message) do
    String.contains?(message, "index.lock")
  end

  defp exec_git(full_path, args, opts) do
    stderr_file =
      Path.join(
        System.tmp_dir!(),
        "iex_code_git_stderr_#{System.system_time(:microsecond)}_#{:erlang.unique_integer([:positive])}"
      )

    # Capture stderr separately via the shell so stdout stays parseable.
    # Set GIT_CEILING_DIRECTORIES to repo_dir's parent so git does not traverse into parent project repo
    parent_dir = Path.dirname(full_path)

    env_prefix =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map_join(" ", fn {key, value} ->
        "#{to_string(key)}=#{shell_quote(to_string(value))}"
      end)

    env_prefix = if env_prefix == "", do: "", else: env_prefix <> " "

    cmd =
      "#{env_prefix}GIT_CEILING_DIRECTORIES=#{shell_quote(parent_dir)} git #{Enum.map_join(args, " ", &shell_quote/1)} 2> #{shell_quote(stderr_file)}"

    try do
      case System.shell(cmd, cd: full_path, env: Keyword.get(opts, :env, [])) do
        {output, 0} ->
          {:ok, output}

        {output, exit_code} ->
          stderr =
            case File.read(stderr_file) do
              {:ok, contents} -> contents
              {:error, _} -> ""
            end

          error_message = git_error_message(stderr, output, exit_code)

          if String.contains?(error_message, "not a git repository") do
            {:error, :not_a_git_repo}
          else
            {:error, {:git_error, exit_code, error_message}}
          end
      end
    rescue
      ex ->
        {:error, ex}
    after
      File.rm(stderr_file)
    end
  end

  defp git_error_message(stderr, output, exit_code) do
    cond do
      String.trim(stderr) != "" -> String.trim(stderr)
      String.trim(output) != "" -> String.trim(output)
      true -> "git exited with code #{exit_code}"
    end
  end

  defp shell_quote(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
