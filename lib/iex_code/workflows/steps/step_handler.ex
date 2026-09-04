defmodule IexCode.Workflows.Steps.StepHandler do
  @moduledoc """
  Behaviour for workflow step execution handlers.
  """

  @type step :: map()
  @type context :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback execute(step :: step(), context :: context()) :: result()
end
