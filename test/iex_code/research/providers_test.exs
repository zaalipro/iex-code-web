defmodule IexCode.Research.ProvidersTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.HTTP

  alias IexCode.Research.Providers.{
    Bing,
    Brave,
    DuckDuckGo,
    Exa,
    Firecrawl,
    GoogleCSE,
    Linkup,
    Perplexity,
    SearxNG,
    SerpApi,
    Serper,
    Tavily
  }

  test "Perplexity calls the structured Search API and clamps its provider limit" do
    request = fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://api.perplexity.ai/search"
      assert opts[:headers] == [{"authorization", "Bearer pplx-secret"}]

      assert opts[:json] == %{
               query: "beam",
               max_results: 20,
               country: "GE",
               search_context_size: "high",
               search_language_filter: ["en"]
             }

      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{
               "title" => "Perplexity result",
               "url" => "https://perplexity.test/result",
               "snippet" => "ranked search",
               "date" => "2026-08-24",
               "last_updated" => "2026-08-24"
             }
           ]
         }
       }}
    end

    assert {:ok, [result]} =
             Perplexity.search("beam",
               api_key: "pplx-secret",
               limit: 50,
               country: "GE",
               language: "en",
               search_depth: "deep",
               request: request
             )

    assert result.provider == "perplexity"
    assert result.published_at == "2026-08-24"
    assert result.metadata["last_updated"] == "2026-08-24"
  end

  test "Firecrawl v2 requests ranked web metadata without full scrape bodies" do
    request = fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://api.firecrawl.dev/v2/search"
      assert opts[:headers] == [{"authorization", "Bearer fc-secret"}]
      assert opts[:json] == %{query: "beam", limit: 7, sources: ["web"], country: "US"}
      refute Map.has_key?(opts[:json], :scrapeOptions)

      {:ok,
       %{
         status: 200,
         body: %{
           "success" => true,
           "data" => %{
             "web" => [
               %{
                 "title" => "Firecrawl result",
                 "url" => "https://firecrawl.test/result",
                 "description" => "search metadata"
               }
             ]
           },
           "creditsUsed" => 1
         }
       }}
    end

    assert {:ok, [result]} =
             Firecrawl.search("beam",
               api_key: "fc-secret",
               limit: 7,
               country: "US",
               request: request
             )

    assert result.provider == "firecrawl"
    assert result.snippet == "search metadata"

    error_request = fn _opts ->
      {:ok, %{status: 200, body: %{"success" => false, "error" => "fc-secret invalid"}}}
    end

    assert {:error, :provider_error} =
             Firecrawl.search("beam", api_key: "fc-secret", request: error_request)
  end

  test "SerpApi uses an allowlisted ranked engine and normalizes organic results" do
    request = fn opts ->
      assert opts[:method] == :get
      assert opts[:url] == "https://serpapi.com/search.json"

      assert opts[:params] == %{
               q: "beam",
               engine: "google",
               api_key: "serp-secret",
               num: 9,
               gl: "us",
               hl: "en"
             }

      {:ok,
       %{
         status: 200,
         body: %{
           "organic_results" => [
             %{
               "position" => 1,
               "title" => "SerpApi result",
               "link" => "https://serpapi.test/result",
               "snippet" => "structured serp"
             }
           ]
         }
       }}
    end

    assert {:ok, [result]} =
             SerpApi.search("beam",
               api_key: "serp-secret",
               engine: "google",
               limit: 9,
               country: "us",
               language: "en",
               request: request
             )

    assert result.provider == "serpapi"
    assert result.score == 1

    assert {:error, :unsupported_engine} =
             SerpApi.search("beam", api_key: "secret", engine: "arbitrary")
  end

  test "Linkup requests searchResults rather than a grounded sourcedAnswer" do
    request = fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://api.linkup.so/v1/search"
      assert opts[:headers] == [{"authorization", "Bearer link-secret"}]

      assert opts[:json] == %{
               q: "beam",
               depth: "deep",
               outputType: "searchResults",
               maxResults: 6
             }

      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{
               "name" => "Linkup result",
               "url" => "https://linkup.test/result",
               "content" => "retrieved context",
               "type" => "text"
             }
           ]
         }
       }}
    end

    assert {:ok, [result]} =
             Linkup.search("beam",
               api_key: "link-secret",
               search_depth: "deep",
               limit: 6,
               request: request
             )

    assert result.provider == "linkup"
    assert result.snippet == "retrieved context"
  end

  test "new official providers reject changed origins and require credentials" do
    for module <- [Perplexity, Firecrawl, SerpApi, Linkup] do
      assert {:error, :missing_api_key} = module.search("query", [])

      assert_raise ArgumentError, fn ->
        module.search("query",
          api_key: "secret",
          base_url: "https://attacker.test",
          request: fn _opts -> flunk("request must not be issued") end
        )
      end
    end
  end

  test "new adapters bound response rows even when an upstream ignores the requested limit" do
    cases = [
      {Perplexity,
       %{
         "results" =>
           for(
             rank <- 1..3,
             do: %{"title" => "P#{rank}", "url" => "https://p.test/#{rank}"}
           )
       }},
      {Firecrawl,
       %{
         "success" => true,
         "data" => %{
           "web" =>
             for(
               rank <- 1..3,
               do: %{"title" => "F#{rank}", "url" => "https://f.test/#{rank}"}
             )
         }
       }},
      {SerpApi,
       %{
         "organic_results" =>
           for(
             rank <- 1..3,
             do: %{"title" => "S#{rank}", "link" => "https://s.test/#{rank}"}
           )
       }},
      {Linkup,
       %{
         "results" =>
           for(
             rank <- 1..3,
             do: %{"name" => "L#{rank}", "url" => "https://l.test/#{rank}"}
           )
       }}
    ]

    for {module, body} <- cases do
      request = fn _opts -> {:ok, %{status: 200, body: body}} end

      assert {:ok, [_one_result]} =
               module.search("beam", api_key: "key", limit: 1, request: request)
    end
  end

  test "modern provider filters are validated before any network request" do
    request = fn _opts -> flunk("invalid options must not issue a request") end

    assert {:error, :conflicting_domain_filters} =
             Firecrawl.search("beam",
               api_key: "key",
               include_domains: ["example.com"],
               exclude_domains: ["other.example"],
               request: request
             )

    assert {:error, :invalid_domain_filter} =
             Firecrawl.search("beam",
               api_key: "key",
               include_domains: ["https://example.com/path"],
               request: request
             )

    assert {:error, :invalid_safe_search} =
             Firecrawl.search("beam", api_key: "key", safe: "yes", request: request)

    assert {:error, :invalid_country} =
             Firecrawl.search("beam", api_key: "key", country: "USA", request: request)

    assert {:error, :invalid_language_filter} =
             Perplexity.search("beam", api_key: "key", language: "eng", request: request)

    assert {:error, :invalid_search_after_date} =
             Perplexity.search("beam",
               api_key: "key",
               search_after_date: "2026-08-24",
               request: request
             )

    assert {:error, :invalid_recency} =
             Perplexity.search("beam", api_key: "key", recency: "forever", request: request)

    assert {:error, :invalid_language} =
             SerpApi.search("beam", api_key: "key", language: ["en", "ka"], request: request)

    assert {:error, :invalid_date_range} =
             Linkup.search("beam",
               api_key: "key",
               start_date: "2026-08-24",
               end_date: "2026-08-01",
               request: request
             )

    assert {:error, :invalid_search_depth} =
             Linkup.search("beam", api_key: "key", search_depth: "exhaustive", request: request)
  end

  test "Tavily maps its response and sends credentials in JSON" do
    request = fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://api.tavily.com/search"
      assert opts[:json].api_key == "secret"

      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{"title" => "T", "url" => "https://t.test", "content" => "S", "score" => 0.8}
           ]
         }
       }}
    end

    assert {:ok, [result]} = Tavily.search("elixir", api_key: "secret", request: request)
    assert result.provider == "tavily"
    assert result.score == 0.8
  end

  test "provider HTTP failures redact configured credentials" do
    request = fn _opts ->
      {:ok, %{status: 401, body: %{"message" => "invalid secret-value"}}}
    end

    assert {:error, {:http_error, 401, body}} =
             Brave.search("query", api_key: "secret-value", request: request)

    assert body["message"] == "invalid [REDACTED]"
    refute inspect(body) =~ "secret-value"
  end

  test "normalizes bounded streamed Req responses from the production response shape" do
    request = fn opts ->
      assert opts[:redirect] == false
      assert opts[:retry] == false
      assert opts[:decode_body] == false
      assert opts[:compressed] == false
      assert is_function(opts[:into], 2)

      req = Req.new()
      response = Req.Response.new(status: 200, headers: %{"content-type" => ["application/json"]})

      assert {:cont, {^req, response}} =
               opts[:into].(
                 {:data, ~s({"results":[{"title":"T","url":"https://t.test","content":"S"}]})},
                 {req, response}
               )

      {:ok, response}
    end

    assert {:ok, [result]} =
             Tavily.search("elixir",
               api_key: "secret",
               redirect: true,
               retry: true,
               decode_body: true,
               compressed: true,
               into: :self,
               request: request
             )

    assert result.url == "https://t.test"
  end

  test "enforces the body cap for streamed and injected map responses" do
    streamed = fn opts ->
      req = Req.new()
      response = Req.Response.new(status: 200)
      chunk = :binary.copy("x", 2_000_001)
      assert {:halt, {^req, response}} = opts[:into].({:data, chunk}, {req, response})
      {:ok, response}
    end

    assert {:error, :response_too_large} =
             HTTP.request(:get, "https://example.test", request: streamed)

    injected = fn _opts ->
      {:ok, %{status: 200, body: :binary.copy("x", 2_000_001)}}
    end

    assert {:error, :response_too_large} =
             HTTP.request(:get, "https://example.test", request: injected)
  end

  test "bounds keyless errors and sanitizes rescue and catch paths" do
    long_error = fn _opts -> {:error, :binary.copy("x", 10_000)} end
    assert {:error, reason} = HTTP.request(:get, "https://example.test", request: long_error)
    assert byte_size(reason) == 4_000

    raising = fn _opts -> raise "credential secret-value failed" end

    assert {:error, {:request_exception, message}} =
             HTTP.request(:get, "https://example.test",
               api_key: "secret-value",
               request: raising
             )

    assert message == "credential [REDACTED] failed"

    throwing = fn _opts -> throw(:binary.copy("y", 10_000)) end

    assert {:error, {:request_failure, :throw, caught}} =
             HTTP.request(:get, "https://example.test", request: throwing)

    assert byte_size(caught) == 4_000

    oversized_map = fn _opts ->
      body = Map.new(1..100, &{"key-#{&1}", :binary.copy("z", 5_000)})
      {:ok, %{status: 500, body: body}}
    end

    assert {:error, {:http_error, 500, body}} =
             HTTP.request(:get, "https://example.test", request: oversized_map)

    assert map_size(body) == 50
    assert Enum.all?(body, fn {_key, value} -> byte_size(value) == 4_000 end)
  end

  test "official providers reject changed origins while custom SearxNG remains injectable" do
    assert_raise ArgumentError, fn ->
      Brave.search("query",
        api_key: "key",
        base_url: "https://attacker.test",
        request: fn _opts -> flunk("request must not be issued") end
      )
    end

    request = fn opts ->
      assert opts[:url] == "https://search.example.test/search"
      {:ok, %{status: 200, body: %{"results" => []}}}
    end

    assert {:ok, []} =
             SearxNG.search("query",
               base_url: "https://search.example.test",
               request: request
             )
  end

  test "all authenticated JSON adapters normalize representative payloads" do
    cases = [
      {Brave,
       %{
         "web" => %{
           "results" => [%{"title" => "B", "url" => "https://b.test", "description" => "brave"}]
         }
       }},
      {Exa, %{"results" => [%{"title" => "E", "url" => "https://e.test", "text" => "exa"}]}},
      {Serper,
       %{"organic" => [%{"title" => "S", "link" => "https://s.test", "snippet" => "serper"}]}},
      {Bing,
       %{
         "webPages" => %{
           "value" => [%{"name" => "Bi", "url" => "https://bi.test", "snippet" => "bing"}]
         }
       }}
    ]

    for {module, body} <- cases do
      request = fn _opts -> {:ok, %{status: 200, body: body}} end
      assert {:ok, [result]} = module.search("query", api_key: "key", request: request)
      assert result.provider == to_string(module.name())
      assert String.starts_with?(result.url, "https://")
    end
  end

  test "Google CSE requires both key and engine identifier" do
    assert {:error, :missing_api_key} = GoogleCSE.search("query", [])
    assert {:error, :missing_cx} = GoogleCSE.search("query", api_key: "key")

    request = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "items" => [%{"title" => "G", "link" => "https://g.test", "snippet" => "google"}]
         }
       }}
    end

    assert {:ok, [result]} =
             GoogleCSE.search("query", api_key: "key", cx: "engine", request: request)

    assert result.provider == "google"
  end

  test "SearxNG requires an instance and parses JSON results" do
    assert {:error, :missing_base_url} = SearxNG.search("query", [])

    request = fn opts ->
      assert opts[:url] == "https://search.internal/search"

      {:ok,
       %{
         status: 200,
         body: %{"results" => [%{"title" => "X", "url" => "https://x.test", "content" => "meta"}]}
       }}
    end

    assert {:ok, [result]} =
             SearxNG.search("query", base_url: "https://search.internal", request: request)

    assert result.provider == "searxng"
  end

  test "DuckDuckGo parses HTML results and unwraps redirect links" do
    html = """
    <div class="result">
      <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Farticle">Article</a>
      <div class="result__snippet">A useful article</div>
    </div>
    """

    request = fn opts ->
      assert opts[:form] == [q: "query"]
      {:ok, %{status: 200, body: html}}
    end

    assert {:ok, [result]} = DuckDuckGo.search("query", request: request)
    assert result.url == "https://example.com/article"
    assert result.snippet == "A useful article"
  end
end
