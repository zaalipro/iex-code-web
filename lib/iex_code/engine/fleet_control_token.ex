defmodule IexCode.Engine.FleetControlToken do
  @moduledoc false

  @paused 1
  @cancelled 2

  def new do
    ref = :atomics.new(2, signed: false)
    %{ref: ref}
  end

  def pause(%{ref: ref}), do: :atomics.put(ref, @paused, 1)
  def resume(%{ref: ref}), do: :atomics.put(ref, @paused, 0)
  def cancel(%{ref: ref}), do: :atomics.put(ref, @cancelled, 1)
  def cancelled?(%{ref: ref}), do: :atomics.get(ref, @cancelled) == 1
  def paused?(%{ref: ref}), do: :atomics.get(ref, @paused) == 1

  def checkpoint(token) do
    cond do
      cancelled?(token) ->
        :cancelled

      paused?(token) ->
        receive do
        after
          25 -> checkpoint(token)
        end

      true ->
        :ok
    end
  end
end
