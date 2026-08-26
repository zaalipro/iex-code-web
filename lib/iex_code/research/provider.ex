defmodule IexCode.Research.Provider do
  @moduledoc "Contract implemented by federated web-search providers."

  alias IexCode.Research.Result

  @callback name() :: atom()
  @callback search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
end
