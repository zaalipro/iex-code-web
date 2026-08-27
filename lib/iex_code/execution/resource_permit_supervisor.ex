defmodule IexCode.Execution.ResourcePermitSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias IexCode.Execution.ResourcePermit

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name,
      do: DynamicSupervisor.start_link(__MODULE__, opts, name: name),
      else: DynamicSupervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_permit(supervisor, owner, ticket_ref)
      when is_pid(owner) and is_reference(ticket_ref) do
    DynamicSupervisor.start_child(
      supervisor,
      {ResourcePermit, owner: owner, ticket_ref: ticket_ref}
    )
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def active_entries(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce_while([], fn
      {_id, pid, :worker, _modules}, entries when is_pid(pid) ->
        case ResourcePermit.entry(pid) do
          {:ok, %{status: :active} = entry} -> {:cont, [entry | entries]}
          {:ok, %{status: :pending}} -> {:cont, entries}
          _unavailable_or_invalid -> {:halt, {:error, :unavailable}}
        end

      _unknown_child, _entries ->
        {:halt, {:error, :unavailable}}
    end)
    |> case do
      {:error, :unavailable} = error -> error
      entries -> Enum.reverse(entries)
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
