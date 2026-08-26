defmodule IexCode.UsageFailureStub do
  @moduledoc false

  def fetch_usage_history(_limit, _opts), do: {:error, {:db_error, "storage unavailable"}}
  def fetch_usage_totals(_opts), do: {:error, {:db_error, "storage unavailable"}}
end
