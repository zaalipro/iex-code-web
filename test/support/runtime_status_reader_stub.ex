defmodule IexCode.RuntimeStatusReaderStub do
  @moduledoc false

  def snapshot do
    case Application.fetch_env!(:iex_code, :runtime_status_reader_stub) do
      :raise -> raise "runtime status unavailable"
      snapshot -> snapshot
    end
  end
end
