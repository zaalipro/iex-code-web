defmodule IexCode.RunDispatcherReconciliationStub do
  @moduledoc false

  def reconcile(opts) do
    notify({:research_result_reconcile, opts})
    []
  end

  def reconcile_claimed(opts) do
    notify({:provider_effect_reconcile, opts})
    []
  end

  defp notify(message) do
    if receiver = Process.whereis(IexCode.RunDispatcherTestReceiver), do: send(receiver, message)
  end
end
