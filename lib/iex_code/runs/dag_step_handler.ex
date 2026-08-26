defmodule IexCode.Runs.DagStepHandler do
  @moduledoc "Contract for a closed, typed DAG step implementation."

  alias IexCode.Runs.{Run, RunStep, RunStepAttempt}

  @type descriptor :: %{
          required(:kind) => String.t(),
          required(:version) => pos_integer(),
          required(:effect_class) =>
            :pure | :read | :workspace_write | :git | :native | :provider,
          required(:replay_policy) => :safe | :checkpointed | :never,
          required(:resource_contract) => String.t(),
          required(:checkpoint_version) => pos_integer(),
          required(:max_output_bytes) => pos_integer(),
          required(:default_timeout_ms) => pos_integer()
        }

  @type context :: %{
          required(:run) => Run.t(),
          required(:step) => RunStep.t(),
          required(:attempt) => RunStepAttempt.t(),
          required(:project_root) => String.t(),
          required(:dependency_results) => map(),
          required(:checkpoint) => map() | nil,
          required(:cancelled?) => (-> boolean()),
          required(:checkpoint_callback) => (map(), non_neg_integer() -> :ok | {:error, term()}),
          required(:provider_effect) => (String.t(), map(), map(), (-> term()), keyword() ->
                                           {:ok, map()} | {:error, term()})
        }

  @callback descriptor() :: descriptor()
  @callback validate_params(map(), [String.t()]) :: :ok | {:error, term()}
  @callback execute(map(), context()) :: {:ok, map()} | {:error, term()}
end
