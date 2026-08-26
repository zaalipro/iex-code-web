defmodule IexCode.WorkspaceLocks do
  use GenServer

  @moduledoc """
  Capability-safe gateway for effects which mutate a project workspace.

  Callers never need to handle the raw capability returned by `IexCode.Runs`.
  The usual entry point is `with_locks/4`; `acquire/3`, `assert/1`, and
  `release/1` are available for effects whose lifetime spans callbacks.
  """

  alias IexCode.Projects.Project
  alias IexCode.{Repo, Runs}

  @derive {Inspect, only: [:batch_id, :project_id, :owner_id, :locks]}
  @enforce_keys [:owner_id]
  defstruct [
    :batch_id,
    :project_id,
    :owner_id,
    :lock_id,
    :capability,
    :heartbeat_pid,
    :waiting_monitor_pid,
    :lease_seconds,
    :heartbeat_interval_ms,
    :heartbeat_failure,
    :run_id,
    :session_id,
    :registry_key,
    :delegation_ref,
    :owner_pid,
    borrowed?: false,
    locks: [],
    unmanaged?: false
  ]

  @opaque t :: %__MODULE__{}
  @type resource ::
          :project
          | :git
          | {:file, Path.t()}
          | {:project | :git, :read | :write | :exclusive}
          | {{:file, Path.t()}, :read | :write | :exclusive}

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_state), do: {:ok, :ets.new(__MODULE__, [:set, :private])}

  @impl true
  def handle_call({:register, key, %__MODULE__{} = handle}, {caller, _tag}, table) do
    reply =
      if caller == handle.owner_pid and key == handle.delegation_ref and is_reference(key) do
        if :ets.insert_new(table, {key, handle}), do: :ok, else: {:error, :already_registered}
      else
        {:error, :unauthorized}
      end

    {:reply, reply, table}
  end

  def handle_call({:borrow, delegation, project, opts, specs}, _from, table) do
    reply =
      with %__MODULE__{} = outer <- registry_get(table, delegation_ref(delegation)),
           true <- valid_delegation?(delegation, outer, project, opts),
           :ok <- assert_capability(outer),
           true <- resources_covered?(outer.locks, project.root_path, specs) do
        {:ok, borrowed_handle(delegation, outer)}
      else
        _other -> :none
      end

    {:reply, reply, table}
  end

  def handle_call({:assert_delegation, delegation}, _from, table) do
    reply =
      case registry_get(table, delegation_ref(delegation)) do
        %__MODULE__{} = outer ->
          if valid_delegation_context?(delegation, outer) do
            assert_capability(outer)
          else
            {:error, :workspace_lock_delegation_expired}
          end

        nil ->
          {:error, :workspace_lock_delegation_expired}
      end

    {:reply, reply, table}
  end

  def handle_call({:unregister, key, lock_id}, {caller, _tag}, table) do
    case registry_get(table, key) do
      %__MODULE__{lock_id: ^lock_id} = outer
      when caller == outer.owner_pid or caller == outer.heartbeat_pid ->
        :ets.delete(table, key)

      _other ->
        :ok
    end

    {:reply, :ok, table}
  end

  def handle_call(_unknown, _from, table), do: {:reply, {:error, :unsupported}, table}

  @doc """
  Acquires a complete resource batch and runs `fun` while heartbeating it.

  The callback result is returned unchanged. A queued batch is immediately
  cancelled and returned as `{:error, {:workspace_lock_waiting, locks}}`.
  """
  @spec with_locks(Project.t() | Path.t(), [resource()], keyword() | map(), (-> result)) ::
          result | {:error, term()}
        when result: term()
  def with_locks(project_or_root, resources, identity_opts, fun)
      when is_function(fun, 0) do
    case acquire(project_or_root, resources, identity_opts) do
      {:ok, handle} ->
        try do
          case assert(handle) do
            :ok -> with_delegation(handle, fun)
            {:error, _reason} = error -> error
          end
        after
          _ = release(handle)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def with_locks(_project_or_root, _resources, _identity_opts, _fun),
    do: {:error, :invalid_workspace_lock_callback}

  @doc "Returns the non-secret durable lock identifier used in gateway notifications."
  @spec handle_id(t()) :: String.t() | nil
  def handle_id(%__MODULE__{lock_id: lock_id}), do: lock_id
  def handle_id(_handle), do: nil

  @doc "Runs a callback with a delegation available only in the current process."
  @spec with_delegation(t(), (-> result)) :: result when result: term()
  def with_delegation(handle, fun) when is_function(fun, 0) do
    with {:ok, delegation} <- delegation_context(handle) do
      previous = Process.get({__MODULE__, :delegation})
      Process.put({__MODULE__, :delegation}, delegation)

      try do
        fun.()
      after
        if is_nil(previous) do
          Process.delete({__MODULE__, :delegation})
        else
          Process.put({__MODULE__, :delegation}, previous)
        end
      end
    end
  end

  def with_delegation(_handle, _fun), do: {:error, :invalid_workspace_lock_callback}

  @doc "Returns the current process's opaque delegation context, if any."
  @spec current_delegation() :: t() | nil
  def current_delegation, do: Process.get({__MODULE__, :delegation})

  @doc "Creates an unforgeable, capability-free context for a covered nested effect."
  @spec delegate(t()) :: {:ok, t()} | {:error, term()}
  def delegate(%__MODULE__{unmanaged?: true} = handle), do: {:ok, handle}

  def delegate(%__MODULE__{borrowed?: false, delegation_ref: ref} = handle)
      when is_reference(ref) do
    {:ok,
     %__MODULE__{
       batch_id: handle.batch_id,
       project_id: handle.project_id,
       owner_id: handle.owner_id,
       lock_id: handle.lock_id,
       run_id: handle.run_id,
       session_id: handle.session_id,
       registry_key: handle.registry_key,
       delegation_ref: ref,
       borrowed?: true,
       locks: handle.locks
     }}
  end

  def delegate(_handle), do: {:error, :invalid_workspace_lock_handle}

  defp delegation_context(%__MODULE__{borrowed?: true} = delegation), do: {:ok, delegation}
  defp delegation_context(%__MODULE__{} = handle), do: delegate(handle)
  defp delegation_context(_handle), do: {:error, :invalid_workspace_lock_handle}

  @doc "Acquires a batch and returns an opaque, automatically heartbeating handle."
  @spec acquire(Project.t() | Path.t(), [resource()], keyword() | map()) ::
          {:ok, t()} | {:error, term()}
  def acquire(project_or_root, resources, identity_opts) do
    do_acquire(project_or_root, resources, identity_opts, :cancel_waiting)
  end

  @doc """
  Acquires a batch while retaining a durable FIFO waiter on conflict.

  This is intended for schedulers which will call `retry/1` and must not lose
  their queue position. Ordinary protected effects should use `acquire/3` or
  `with_locks/4` instead.
  """
  @spec acquire_or_wait(Project.t() | Path.t(), [resource()], keyword() | map()) ::
          {:ok, t()} | {:waiting, t()} | {:error, term()}
  def acquire_or_wait(project_or_root, resources, identity_opts) do
    do_acquire(project_or_root, resources, identity_opts, :retain_waiting)
  end

  @doc "Rechecks a durable waiter, preserving its capability and FIFO position."
  @spec retry(t()) :: {:ok, t()} | {:waiting, t()} | {:error, term()}
  def retry(%__MODULE__{unmanaged?: true} = handle), do: {:ok, handle}

  def retry(%__MODULE__{heartbeat_pid: pid} = handle) when is_pid(pid), do: {:ok, handle}

  def retry(%__MODULE__{} = handle) do
    case Runs.retry_workspace_lock(handle.lock_id, handle.capability, handle.lease_seconds) do
      {:ok, %{locks: locks} = envelope} ->
        if Enum.all?(locks, &(&1.status == "held")) do
          stop_heartbeat(handle.waiting_monitor_pid)

          envelope = %{envelope | capability_token: handle.capability}

          start_handle(handle.project_id, envelope, %{
            owner_id: handle.owner_id,
            lease_seconds: handle.lease_seconds,
            heartbeat_interval_ms: handle.heartbeat_interval_ms,
            heartbeat_failure: handle.heartbeat_failure,
            run_id: handle.run_id,
            session_id: handle.session_id
          })
        else
          {:waiting, %{handle | locks: locks}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> database_error(exception)
  end

  def retry(_handle), do: {:error, :invalid_workspace_lock_handle}

  defp do_acquire(project_or_root, resources, identity_opts, waiting_policy) do
    with {:ok, opts} <- normalize_opts(identity_opts),
         {:ok, resolved} <- resolve_project(project_or_root, opts),
         {:ok, specs} <- normalize_resources(resources) do
      case resolved do
        :unmanaged ->
          {:ok,
           %__MODULE__{
             owner_id: opts.owner_id,
             unmanaged?: true
           }}

        %Project{} = project ->
          acquire_managed(project, specs, opts, waiting_policy)
      end
    end
  end

  @doc "Asserts that every lock in a handle is still held."
  @spec assert(t()) :: :ok | {:error, term()}
  def assert(%__MODULE__{unmanaged?: true}), do: :ok

  def assert(%__MODULE__{borrowed?: true, registry_key: key, lock_id: lock_id}) do
    delegation = %__MODULE__{
      owner_id: "delegated",
      registry_key: key,
      delegation_ref: key,
      lock_id: lock_id,
      borrowed?: true
    }

    try do
      GenServer.call(__MODULE__, {:assert_delegation, delegation})
    catch
      :exit, _reason -> {:error, :workspace_lock_delegation_expired}
    end
  end

  def assert(%__MODULE__{lock_id: lock_id, capability: capability})
      when is_binary(lock_id) and is_binary(capability) do
    case Runs.assert_workspace_lock(lock_id, capability) do
      {:ok, _envelope} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> database_error(exception)
  end

  def assert(_handle), do: {:error, :invalid_workspace_lock_handle}

  @doc "Stops heartbeating and releases the complete batch. Idempotent."
  @spec release(t()) :: :ok | {:error, term()}
  def release(%__MODULE__{unmanaged?: true}), do: :ok
  def release(%__MODULE__{borrowed?: true}), do: :ok

  def release(%__MODULE__{} = handle) do
    unregister_handle(handle)
    stop_heartbeat(handle.heartbeat_pid)
    stop_heartbeat(handle.waiting_monitor_pid)

    case Runs.release_workspace_lock(handle.lock_id, handle.capability) do
      {:ok, _envelope} -> :ok
      {:error, {:lock_batch_not_active, _statuses}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> database_error(exception)
  end

  def release(_handle), do: {:error, :invalid_workspace_lock_handle}

  defp acquire_managed(project, specs, opts, waiting_policy) do
    case borrow_handle(project, specs, opts) do
      {:ok, handle} ->
        {:ok, handle}

      :none ->
        attrs = Enum.map(specs, &lock_attrs(project.id, &1, opts))

        case Runs.acquire_workspace_locks(attrs) do
          {:ok, %{locks: locks} = envelope} ->
            if Enum.all?(locks, &(&1.status == "held")) do
              start_handle(project.id, envelope, opts)
            else
              case waiting_policy do
                :cancel_waiting -> release_waiting(envelope)
                :retain_waiting -> {:waiting, waiting_handle(project.id, envelope, opts)}
              end
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    exception -> database_error(exception)
  end

  defp start_handle(project_id, envelope, opts) do
    first = hd(envelope.locks)
    owner = self()
    delegation_ref = make_ref()

    case Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
           heartbeat_loop(
             owner,
             delegation_ref,
             first.id,
             envelope.capability_token,
             opts.lease_seconds,
             opts.heartbeat_interval_ms,
             Map.get(opts, :heartbeat_failure, :exit_owner)
           )
         end) do
      {:ok, heartbeat_pid} ->
        handle = %__MODULE__{
          batch_id: envelope.batch_id,
          project_id: project_id,
          owner_id: opts.owner_id,
          lock_id: first.id,
          capability: envelope.capability_token,
          heartbeat_pid: heartbeat_pid,
          lease_seconds: opts.lease_seconds,
          heartbeat_interval_ms: opts.heartbeat_interval_ms,
          heartbeat_failure: Map.get(opts, :heartbeat_failure, :exit_owner),
          run_id: Map.get(opts, :run_id),
          session_id: Map.get(opts, :session_id),
          registry_key: delegation_ref,
          delegation_ref: delegation_ref,
          owner_pid: owner,
          locks: envelope.locks
        }

        case register_handle(handle) do
          :ok ->
            {:ok, handle}

          {:error, reason} ->
            stop_heartbeat(heartbeat_pid)
            _ = Runs.release_workspace_lock(first.id, envelope.capability_token)
            {:error, {:workspace_lock_registry_failed, reason}}
        end

      {:error, reason} ->
        _ = Runs.release_workspace_lock(first.id, envelope.capability_token)
        {:error, {:workspace_lock_heartbeat_start_failed, reason}}
    end
  end

  defp waiting_handle(project_id, envelope, opts) do
    first = hd(envelope.locks)
    owner = self()
    monitor_pid = start_waiting_monitor(owner, first.id, envelope.capability_token)

    %__MODULE__{
      batch_id: envelope.batch_id,
      project_id: project_id,
      owner_id: opts.owner_id,
      lock_id: first.id,
      capability: envelope.capability_token,
      lease_seconds: opts.lease_seconds,
      heartbeat_interval_ms: opts.heartbeat_interval_ms,
      heartbeat_failure: Map.get(opts, :heartbeat_failure, :exit_owner),
      waiting_monitor_pid: monitor_pid,
      run_id: Map.get(opts, :run_id),
      session_id: Map.get(opts, :session_id),
      locks: envelope.locks
    }
  end

  defp start_waiting_monitor(owner, lock_id, capability) do
    case Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
           waiting_monitor_loop(owner, Process.monitor(owner), lock_id, capability)
         end) do
      {:ok, pid} -> pid
      {:error, _reason} -> nil
    end
  end

  defp waiting_monitor_loop(owner, owner_ref, lock_id, capability) do
    receive do
      {:stop_workspace_lock_heartbeat, from, ref} ->
        send(from, {:workspace_lock_heartbeat_stopped, ref})
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        _ = safe_release(lock_id, capability)
        :ok
    end
  end

  defp borrow_handle(project, specs, opts) do
    delegation = opts.delegation

    GenServer.call(__MODULE__, {:borrow, delegation, project, opts, specs})
  catch
    :exit, _reason -> :none
  end

  defp borrowed_handle(delegation, outer) do
    %__MODULE__{
      batch_id: outer.batch_id,
      project_id: outer.project_id,
      owner_id: outer.owner_id,
      lock_id: outer.lock_id,
      run_id: outer.run_id,
      session_id: outer.session_id,
      registry_key: outer.registry_key,
      delegation_ref: delegation.delegation_ref,
      borrowed?: true,
      locks: outer.locks
    }
  end

  defp valid_delegation?(delegation, outer, project, opts) do
    valid_delegation_context?(delegation, outer) and outer.project_id == project.id and
      outer.owner_id == opts.owner_id and outer.run_id == opts.run_id and
      outer.session_id == opts.session_id
  end

  defp valid_delegation_context?(delegation, outer) do
    match?(%__MODULE__{borrowed?: true}, delegation) and
      is_reference(delegation.delegation_ref) and
      delegation.delegation_ref == outer.delegation_ref and delegation.lock_id == outer.lock_id and
      delegation.registry_key == outer.registry_key
  end

  defp delegation_ref(%__MODULE__{borrowed?: true, delegation_ref: ref}), do: ref
  defp delegation_ref(_delegation), do: nil

  defp resources_covered?(locks, root, specs) do
    Enum.any?(locks, &(&1.resource_type == "project" and &1.mode == "exclusive")) or
      Enum.all?(specs, fn {type, key, requested_mode} ->
        requested_key = canonical_resource_key(root, type, key)

        Enum.any?(locks, fn held ->
          held.resource_type == type and held.resource_key == requested_key and
            mode_rank(held.mode) >= mode_rank(requested_mode)
        end)
      end)
  end

  defp canonical_resource_key(root, "file", key) do
    case IexCode.WorkspacePath.resolve(root, key) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp canonical_resource_key(root, type, _key) when type in ["project", "git"],
    do: Path.expand(root)

  defp mode_rank("read"), do: 1
  defp mode_rank("write"), do: 2
  defp mode_rank("exclusive"), do: 3

  defp register_handle(handle) do
    GenServer.call(__MODULE__, {:register, handle.registry_key, handle})
  catch
    :exit, reason -> {:error, reason}
  end

  defp unregister_handle(handle) do
    unregister_key(handle.registry_key, handle.lock_id)
  end

  defp unregister_key(key, lock_id) do
    GenServer.call(__MODULE__, {:unregister, key, lock_id})
  catch
    :exit, _reason -> :ok
  end

  defp registry_get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, handle}] -> handle
      [] -> nil
    end
  end

  defp assert_capability(outer) do
    case Runs.assert_workspace_lock(outer.lock_id, outer.capability) do
      {:ok, _envelope} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> database_error(exception)
  end

  defp release_waiting(envelope) do
    first = hd(envelope.locks)

    case Runs.release_workspace_lock(first.id, envelope.capability_token) do
      {:ok, _released} -> {:error, {:workspace_lock_waiting, envelope.locks}}
      {:error, reason} -> {:error, {:workspace_lock_release_failed, reason}}
    end
  end

  defp heartbeat_loop(
         owner,
         registry_key,
         lock_id,
         capability,
         lease_seconds,
         interval_ms,
         heartbeat_failure
       ) do
    owner_ref = Process.monitor(owner)

    do_heartbeat_loop(
      owner,
      owner_ref,
      registry_key,
      lock_id,
      capability,
      lease_seconds,
      interval_ms,
      heartbeat_failure
    )
  end

  defp do_heartbeat_loop(
         owner,
         owner_ref,
         registry_key,
         lock_id,
         capability,
         lease_seconds,
         interval_ms,
         heartbeat_failure
       ) do
    receive do
      {:stop_workspace_lock_heartbeat, from, ref} ->
        send(from, {:workspace_lock_heartbeat_stopped, ref})
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        _ = unregister_key(registry_key, lock_id)
        _ = safe_release(lock_id, capability)
        :ok
    after
      interval_ms ->
        case safe_heartbeat(lock_id, capability, lease_seconds) do
          {:ok, _envelope} ->
            do_heartbeat_loop(
              owner,
              owner_ref,
              registry_key,
              lock_id,
              capability,
              lease_seconds,
              interval_ms,
              heartbeat_failure
            )

          {:error, reason} ->
            failure = {:workspace_lock_heartbeat_failed, lock_id, reason}
            _ = unregister_key(registry_key, lock_id)
            send(owner, failure)
            if heartbeat_failure == :exit_owner, do: Process.exit(owner, failure)
            :ok
        end
    end
  end

  defp safe_heartbeat(lock_id, capability, lease_seconds) do
    Runs.heartbeat_workspace_lock(lock_id, capability, lease_seconds)
  rescue
    exception -> database_error(exception)
  catch
    kind, reason -> {:error, {:workspace_lock_heartbeat_exception, kind, reason}}
  end

  defp safe_release(lock_id, capability) do
    Runs.release_workspace_lock(lock_id, capability)
  rescue
    _exception -> :ok
  catch
    _, _ -> :ok
  end

  defp stop_heartbeat(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = make_ref()
      send(pid, {:stop_workspace_lock_heartbeat, self(), ref})

      receive do
        {:workspace_lock_heartbeat_stopped, ^ref} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defp stop_heartbeat(_pid), do: :ok

  defp lock_attrs(project_id, {resource_type, resource_key, mode}, opts) do
    %{
      project_id: project_id,
      owner_id: opts.owner_id,
      run_id: opts.run_id,
      session_id: opts.session_id,
      resource_type: resource_type,
      resource_key: resource_key,
      mode: mode,
      lease_seconds: opts.lease_seconds
    }
  end

  defp normalize_resources(resources) when is_list(resources) and resources != [] do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, normalized} ->
      case normalize_resource(resource) do
        {:ok, spec} -> {:cont, {:ok, [spec | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_resources(_resources), do: {:error, :invalid_workspace_lock_resources}

  defp normalize_resource(:project), do: {:ok, {"project", ".", "exclusive"}}
  defp normalize_resource(:git), do: {:ok, {"git", ".", "exclusive"}}
  defp normalize_resource({:file, path}), do: normalize_resource({{:file, path}, :write})

  defp normalize_resource({resource, mode}) when resource in [:project, :git] do
    with {:ok, mode} <- normalize_mode(mode) do
      {:ok, {Atom.to_string(resource), ".", mode}}
    end
  end

  defp normalize_resource({{:file, path}, mode}) when is_binary(path) and path != "" do
    with {:ok, mode} <- normalize_mode(mode) do
      {:ok, {"file", path, mode}}
    end
  end

  defp normalize_resource(%{} = resource) do
    type = value(resource, :resource_type) || value(resource, :type)
    key = value(resource, :resource_key) || value(resource, :path) || "."
    mode = value(resource, :mode)

    case {type, key, mode} do
      {type, key, mode} when type in [:file, "file"] and is_binary(key) ->
        normalize_resource({{:file, key}, mode})

      {type, _key, mode} when type in [:project, "project", :workspace, "workspace"] ->
        normalize_resource({:project, mode})

      {type, _key, mode} when type in [:git, "git"] ->
        normalize_resource({:git, mode})

      _ ->
        {:error, {:invalid_workspace_lock_resource, resource}}
    end
  end

  defp normalize_resource(resource),
    do: {:error, {:invalid_workspace_lock_resource, resource}}

  defp normalize_mode(mode) when mode in [:read, :write, :exclusive],
    do: {:ok, Atom.to_string(mode)}

  defp normalize_mode(mode) when mode in ["read", "write", "exclusive"], do: {:ok, mode}
  defp normalize_mode(_mode), do: {:error, :invalid_workspace_lock_mode}

  defp normalize_opts(opts) when is_list(opts), do: opts |> Map.new() |> normalize_opts()

  defp normalize_opts(%{} = opts) do
    owner_id = value(opts, :owner_id)
    lease_seconds = value(opts, :lease_seconds) || 60

    heartbeat_interval_ms =
      value(opts, :heartbeat_interval_ms) || max(250, div(lease_seconds * 1_000, 3))

    cond do
      not (is_binary(owner_id) and owner_id != "") ->
        {:error, {:missing, :owner_id}}

      not (is_integer(lease_seconds) and lease_seconds >= 1 and lease_seconds <= 86_400) ->
        {:error, :invalid_lease_seconds}

      not (is_integer(heartbeat_interval_ms) and heartbeat_interval_ms > 0 and
               heartbeat_interval_ms < lease_seconds * 1_000) ->
        {:error, :invalid_workspace_lock_heartbeat_interval}

      value(opts, :heartbeat_failure) not in [nil, :exit_owner, :notify] ->
        {:error, :invalid_workspace_lock_heartbeat_failure}

      true ->
        {:ok,
         %{
           owner_id: owner_id,
           project_id: optional_binary(opts, :project_id),
           run_id: optional_binary(opts, :run_id),
           session_id: optional_binary(opts, :session_id),
           lease_seconds: lease_seconds,
           heartbeat_interval_ms: heartbeat_interval_ms,
           heartbeat_failure: value(opts, :heartbeat_failure) || :exit_owner,
           delegation: value(opts, :delegation),
           allow_unmanaged: value(opts, :allow_unmanaged) == true
         }}
    end
  end

  defp normalize_opts(_opts), do: {:error, :invalid_workspace_lock_identity}

  defp resolve_project(%Project{id: id, root_path: root_path}, opts) do
    case Repo.get(Project, id) do
      %Project{} = registered -> validate_project(registered, root_path, opts)
      nil -> {:error, :unmanaged_workspace}
    end
  rescue
    exception -> database_error(exception)
  end

  defp resolve_project(root, opts) when is_binary(root) and root != "" do
    expanded = Path.expand(root)

    lookup_project_root(expanded, opts)
  rescue
    exception ->
      if unmanaged_sandbox_fallback?(exception, opts) do
        {:ok, :unmanaged}
      else
        database_error(exception)
      end
  end

  defp resolve_project(_project_or_root, _opts), do: {:error, :invalid_workspace}

  defp lookup_project_root(expanded, opts) do
    case Repo.get_by(Project, root_path: expanded) do
      %Project{} = project ->
        validate_project(project, expanded, opts)

      nil when is_binary(opts.project_id) ->
        case Repo.get(Project, opts.project_id) do
          %Project{} = project -> validate_project(project, expanded, opts)
          nil -> {:error, {:invalid, :project_id}}
        end

      nil when opts.allow_unmanaged ->
        if test_environment?(), do: {:ok, :unmanaged}, else: {:error, :unmanaged_workspace}

      nil ->
        {:error, :unmanaged_workspace}
    end
  end

  defp validate_project(project, expected_root, opts) do
    cond do
      Path.expand(project.root_path) != Path.expand(expected_root) ->
        {:error, :project_path_mismatch}

      is_binary(opts.project_id) and opts.project_id != project.id ->
        {:error, :project_id_mismatch}

      true ->
        {:ok, project}
    end
  end

  defp optional_binary(opts, key) do
    case value(opts, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp unmanaged_sandbox_fallback?(exception, opts) do
    test_environment?() and opts.allow_unmanaged and is_nil(opts.project_id) and
      String.contains?(Exception.message(exception), "cannot find ownership process")
  end

  defp test_environment? do
    Application.get_env(:iex_code, Repo, [])[:pool] == Ecto.Adapters.SQL.Sandbox
  end

  defp database_error(exception) do
    {:error, {:workspace_lock_database_error, Exception.message(exception)}}
  end
end
