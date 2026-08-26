defmodule IexCode.Research.SearchTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.{Registry, Search}

  test "runs enabled atom/string providers, deduplicates URLs, and retains partial errors" do
    request = fn opts ->
      case opts[:url] do
        "https://html.duckduckgo.com/html/" ->
          {:ok,
           %{
             status: 200,
             body:
               "<div class='result'><a class='result__a' href='https://same.test/path/'>One</a><span class='result__snippet'>first</span></div>"
           }}

        "https://google.serper.dev/search" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "organic" => [
                 %{
                   "title" => "Duplicate",
                   "link" => "https://same.test/path",
                   "snippet" => "second"
                 },
                 %{"title" => "Two", "link" => "https://other.test", "snippet" => "other"}
               ]
             }
           }}
      end
    end

    config = %{"serper" => %{"api_key" => "key"}}

    assert {:ok, response} =
             Search.search("beam",
               providers: [:duckduckgo, "serper", :tavily],
               config: config,
               request: request
             )

    assert Enum.map(response.results, & &1.url) == [
             "https://same.test/path/",
             "https://other.test"
           ]

    assert [duckduckgo_source, serper_source] =
             response.results |> hd() |> Map.fetch!(:metadata) |> Map.fetch!("provenance")

    assert duckduckgo_source["provider"] == "duckduckgo"
    assert duckduckgo_source["snippet"] == "first"
    assert serper_source["provider"] == "serper"
    assert serper_source["snippet"] == "second"

    assert response.errors == %{"tavily" => :missing_api_key}
    assert response.providers == ["duckduckgo", "serper"]
  end

  test "interleaves successful providers by rank before callers apply a result budget" do
    request = fn opts ->
      body =
        case opts[:url] do
          "https://google.serper.dev/search" ->
            %{
              "organic" =>
                for rank <- 1..3 do
                  %{
                    "title" => "Serper #{rank}",
                    "link" => "https://serper.test/#{rank}"
                  }
                end
            }

          "https://api.search.brave.com/res/v1/web/search" ->
            %{
              "web" => %{
                "results" =>
                  for rank <- 1..2 do
                    %{
                      "title" => "Brave #{rank}",
                      "url" => "https://brave.test/#{rank}"
                    }
                  end
              }
            }

          "https://api.exa.ai/search" ->
            %{
              "results" => [
                %{"title" => "Exa 1", "url" => "https://exa.test/1"}
              ]
            }
        end

      {:ok, %{status: 200, body: body}}
    end

    config = %{
      "serper" => %{"api_key" => "serper-key"},
      "brave" => %{"api_key" => "brave-key"},
      "exa" => %{"api_key" => "exa-key"}
    }

    assert {:ok, response} =
             Search.search("beam",
               providers: [:serper, :brave, :exa],
               config: config,
               request: request
             )

    assert Enum.map(response.results, & &1.provider) == [
             "serper",
             "brave",
             "exa",
             "serper",
             "brave",
             "serper"
           ]
  end

  test "federates the four modern ranked providers without treating grounded answers as results" do
    request = fn opts ->
      body =
        case opts[:url] do
          "https://api.perplexity.ai/search" ->
            %{"results" => [%{"title" => "P", "url" => "https://same.test", "snippet" => "p"}]}

          "https://api.firecrawl.dev/v2/search" ->
            %{
              "success" => true,
              "data" => %{
                "web" => [
                  %{"title" => "F", "url" => "https://firecrawl.test", "description" => "f"}
                ]
              }
            }

          "https://serpapi.com/search.json" ->
            %{
              "organic_results" => [
                %{"title" => "S", "link" => "https://same.test/", "snippet" => "s"}
              ]
            }

          "https://api.linkup.so/v1/search" ->
            %{
              "results" => [
                %{"name" => "L", "url" => "https://linkup.test", "content" => "l"}
              ]
            }
        end

      {:ok, %{status: 200, body: body}}
    end

    config =
      Map.new(~w(perplexity firecrawl serpapi linkup), fn provider ->
        {provider, %{"api_key" => "#{provider}-key"}}
      end)

    assert {:ok, response} =
             Search.search("beam",
               providers: ~w(perplexity firecrawl serpapi linkup),
               config: config,
               request: request
             )

    assert response.providers == ~w(perplexity firecrawl serpapi linkup)
    assert Enum.map(response.results, & &1.provider) == ~w(perplexity firecrawl linkup)

    assert Enum.map(hd(response.results).metadata["provenance"], & &1["provider"]) ==
             ~w(perplexity serpapi)
  end

  test "reports all-provider failure and validates selection" do
    assert {:error, :invalid_query} = Search.search("  ")
    assert {:error, :no_providers} = Search.search("query", providers: [:unknown])

    assert {:error,
            {:all_providers_failed, %{"brave" => :missing_api_key, "tavily" => :missing_api_key}}} =
             Search.search("query", providers: [:brave, :tavily])
  end

  test "provider configuration unwraps settings-shaped maps and honors enabled flags" do
    config = %{
      search_providers: %{
        "duckduckgo" => %{"enabled" => false},
        "brave" => %{"enabled" => true, "api_key" => "key"}
      }
    }

    assert [{:brave, IexCode.Research.Providers.Brave, provider_config}] =
             Registry.configured_providers(config)

    assert provider_config["api_key"] == "key"
  end

  test "configuration selection skips retired providers while an explicit list may opt in" do
    config = %{
      search_provider_order: ["bing", "brave"],
      search_providers: %{
        "bing" => %{"enabled" => true, "api_key" => "old-key"},
        "brave" => %{"enabled" => true, "api_key" => "key"}
      }
    }

    assert [{:brave, IexCode.Research.Providers.Brave, _provider_config}] =
             Registry.configured(config)

    request = fn opts ->
      assert opts[:url] == "https://api.bing.microsoft.com/v7.0/search"

      {:ok,
       %{
         status: 200,
         body: %{
           "webPages" => %{
             "value" => [
               %{"name" => "Archived", "url" => "https://archive.test", "snippet" => "old"}
             ]
           }
         }
       }}
    end

    assert {:ok, %{providers: ["bing"], results: [result]}} =
             Search.search("compatibility",
               providers: [:bing],
               config: config,
               request: request
             )

    assert result.provider == "bing"
  end
end
