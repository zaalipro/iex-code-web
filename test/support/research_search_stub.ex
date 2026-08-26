defmodule IexCode.TestResearchSearchStub do
  @moduledoc false

  def search(query, opts) do
    send(self(), {:research_search, query, opts})

    {:ok,
     %{
       providers: ["brave", "tavily"],
       errors: %{"brave" => :timeout},
       results: [
         %{
           provider: "tavily",
           title: "Durable orchestration",
           url: "https://example.test/durable",
           snippet: "Durable workers persist checkpoints before continuing.",
           score: 0.9
         },
         %{
           provider: "brave",
           title: "Agent research systems",
           url: "https://example.test/agents",
           snippet: "Evidence provenance is necessary for trustworthy synthesis.",
           score: 0.8
         }
       ]
     }}
  end
end
