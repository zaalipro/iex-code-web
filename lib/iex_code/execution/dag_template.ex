defmodule IexCode.Execution.DagTemplate do
  @moduledoc """
  Closed, non-mutating DAG used when ordinary background text selects the DAG
  execution mode without supplying a reviewed custom manifest.
  """

  @steps [
    %{
      "key" => "inventory",
      "kind" => "project_inventory",
      "title" => "Inventory project root",
      "depends_on" => [],
      "params" => %{"path" => "."},
      "max_attempts" => 2
    },
    %{
      "key" => "read_readme",
      "kind" => "read_file",
      "title" => "Read README",
      "depends_on" => ["inventory"],
      "params" => %{"path" => "README.md"},
      "max_attempts" => 2
    },
    %{
      "key" => "read_project",
      "kind" => "read_file",
      "title" => "Read project plan",
      "depends_on" => ["inventory"],
      "params" => %{"path" => "PROJECT.md"},
      "max_attempts" => 2
    },
    %{
      "key" => "aggregate",
      "kind" => "aggregate",
      "title" => "Aggregate project evidence",
      "depends_on" => ["read_readme", "read_project"],
      "params" => %{},
      "max_attempts" => 1
    }
  ]

  @spec steps() :: [map()]
  def steps, do: @steps
end
