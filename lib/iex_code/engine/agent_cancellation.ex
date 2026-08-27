defmodule IexCode.Engine.AgentCancellation do
  @moduledoc false

  @cancelled 1

  @type t :: %{ref: :atomics.atomics_ref()}

  @spec new(boolean()) :: t()
  def new(cancelled? \\ false) when is_boolean(cancelled?) do
    ref = :atomics.new(1, signed: false)
    :ok = :atomics.put(ref, @cancelled, if(cancelled?, do: 1, else: 0))
    %{ref: ref}
  end

  @spec cancel(t() | nil) :: :ok
  def cancel(nil), do: :ok
  def cancel(%{ref: ref}), do: :atomics.put(ref, @cancelled, 1)

  @spec resume(t() | nil) :: :ok
  def resume(nil), do: :ok
  def resume(%{ref: ref}), do: :atomics.put(ref, @cancelled, 0)

  @spec cancelled?(t()) :: boolean()
  def cancelled?(%{ref: ref}), do: :atomics.get(ref, @cancelled) == 1

  @doc false
  def erase_legacy(module, session_id) when is_atom(module) and is_binary(session_id) do
    key = {module, :cancelled?, session_id}

    if :persistent_term.get(key, :missing) != :missing do
      :persistent_term.erase(key)
    end

    :ok
  end
end
