defmodule IexCode.E2E.MockLLMServer do
  @moduledoc """
  In-memory HTTP Server-Sent Events (SSE) Mock Server powered by Bandit & Plug.
  Simulates OpenAI-compatible endpoints (`/v1/chat/completions`) and Anthropic endpoints (`/v1/messages`).
  Supports SSE chunk streaming, split-multibyte UTF-8 boundaries, HTTP 429/500 retries, and tool calls.
  """
  use GenServer
  require Logger

  # --- Client API ---

  @doc """
  Starts the mock server and returns `{:ok, server_pid, server_info}` where
  `server_info` contains `%{url: url, port: port, bandit_pid: bandit_pid}`.
  """
  def start(opts \\ []) do
    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} ->
        info = GenServer.call(pid, :get_info)
        {:ok, pid, info}

      error ->
        error
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(server_pid) do
    if Process.alive?(server_pid) do
      GenServer.stop(server_pid, :normal, 5000)
    else
      :ok
    end
  end

  def set_scenario(server_pid, scenario) do
    GenServer.call(server_pid, {:set_scenario, scenario})
  end

  def get_scenario(server_pid) do
    GenServer.call(server_pid, :get_scenario)
  end

  def get_requests(server_pid) do
    GenServer.call(server_pid, :get_requests)
  end

  def clear_requests(server_pid) do
    GenServer.call(server_pid, :clear_requests)
  end

  def record_request(server_pid, request_data) do
    GenServer.cast(server_pid, {:record_request, request_data})
  end

  def increment_attempt(server_pid, endpoint) do
    GenServer.call(server_pid, {:increment_attempt, endpoint})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    scenario = Keyword.get(opts, :scenario, :standard_completion)
    server_pid = self()

    plug_spec = {IexCode.E2E.MockLLMServer.Router, [server_pid: server_pid]}

    # Start Bandit on ephemeral port 0
    {:ok, bandit_pid} =
      Bandit.start_link(
        plug: plug_spec,
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit_pid)
    url = "http://127.0.0.1:#{port}"

    {:ok,
     %{
       bandit_pid: bandit_pid,
       port: port,
       url: url,
       scenario: scenario,
       requests: [],
       attempts: %{}
     }}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      url: state.url,
      port: state.port,
      bandit_pid: state.bandit_pid,
      server_pid: self()
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call({:set_scenario, scenario}, _from, state) do
    {:reply, :ok, %{state | scenario: scenario}}
  end

  @impl true
  def handle_call(:get_scenario, _from, state) do
    {:reply, state.scenario, state}
  end

  @impl true
  def handle_call(:get_requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  @impl true
  def handle_call(:clear_requests, _from, state) do
    {:reply, :ok, %{state | requests: [], attempts: %{}}}
  end

  @impl true
  def handle_call({:increment_attempt, endpoint}, _from, state) do
    current = Map.get(state.attempts, endpoint, 0) + 1
    new_attempts = Map.put(state.attempts, endpoint, current)
    {:reply, current, %{state | attempts: new_attempts}}
  end

  @impl true
  def handle_cast({:record_request, req}, state) do
    {:noreply, %{state | requests: [req | state.requests]}}
  end

  @impl true
  def terminate(_reason, state) do
    if state[:bandit_pid] && Process.alive?(state.bandit_pid) do
      Process.exit(state.bandit_pid, :shutdown)
    end

    :ok
  end

  # --- Plug Router Implementation ---

  defmodule Router do
    use Plug.Router

    def call(conn, opts) do
      conn = Plug.Conn.put_private(conn, :mock_server_pid, opts[:server_pid])
      super(conn, opts)
    end

    plug :match

    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Jason

    plug :dispatch

    post "/v1/chat/completions" do
      server_pid = conn.private[:mock_server_pid]

      IexCode.E2E.MockLLMServer.record_request(server_pid, %{
        method: "POST",
        path: conn.request_path,
        headers: conn.req_headers,
        body: conn.body_params
      })

      scenario = IexCode.E2E.MockLLMServer.get_scenario(server_pid)
      handle_openai_completion(conn, scenario, server_pid)
    end

    post "/v1/messages" do
      server_pid = conn.private[:mock_server_pid]

      IexCode.E2E.MockLLMServer.record_request(server_pid, %{
        method: "POST",
        path: conn.request_path,
        headers: conn.req_headers,
        body: conn.body_params
      })

      scenario = IexCode.E2E.MockLLMServer.get_scenario(server_pid)
      handle_anthropic_message(conn, scenario, server_pid)
    end

    match _ do
      send_resp(conn, 404, "Not Found")
    end

    # --- Scenario Handlers for OpenAI ---

    defp handle_openai_completion(conn, :standard_completion, _server_pid) do
      resp_body = %{
        "id" => "chatcmpl-mock-#{System.unique_integer([:positive])}",
        "object" => "chat.completion",
        "created" => System.system_time(:second),
        "model" => "mock-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "IexCode autonomous response generated successfully."
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"total_tokens" => 42, "prompt_tokens" => 20, "completion_tokens" => 22}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp_body))
    end

    defp handle_openai_completion(conn, {:custom_content, text}, _server_pid) do
      resp_body = %{
        "id" => "chatcmpl-mock-custom",
        "object" => "chat.completion",
        "created" => System.system_time(:second),
        "model" => "mock-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => text
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"total_tokens" => 50}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp_body))
    end

    defp handle_openai_completion(conn, {:tool_call, tool_name, args}, _server_pid) do
      resp_body = %{
        "id" => "chatcmpl-mock-tool",
        "object" => "chat.completion",
        "created" => System.system_time(:second),
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_#{Ecto.UUID.generate()}",
                  "type" => "function",
                  "function" => %{
                    "name" => to_string(tool_name),
                    "arguments" => if(is_binary(args), do: args, else: Jason.encode!(args))
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp_body))
    end

    defp handle_openai_completion(conn, :sse_chunks, _server_pid) do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      chunks = ["Analyzing", " codebase", "...", "\nTask", " completed!"]

      Enum.each(chunks, fn text ->
        chunk_data = %{
          "choices" => [%{"delta" => %{"content" => text}, "index" => 0}]
        }

        chunk(conn, "data: #{Jason.encode!(chunk_data)}\n\n")
        Process.sleep(10)
      end)

      chunk(conn, "data: [DONE]\n\n")
      conn
    end

    defp handle_openai_completion(conn, :split_utf8, _server_pid) do
      # Emoji 🐝 is 4 bytes: <<0xF0, 0x9F, 0x90, 0x9D>>
      # Deliberately split across 2 chunks to test UTF8Buffer normalization
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      # Chunk 1: "Swarm " + first 2 bytes of 🐝
      chunk_1 =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Swarm " <> <<0xF0, 0x9F>> <> "\"}}]}\n\n"

      chunk(conn, chunk_1)
      Process.sleep(10)

      # Chunk 2: last 2 bytes of 🐝 + " Active"
      chunk_2 =
        "data: {\"choices\":[{\"delta\":{\"content\":\"" <> <<0x90, 0x9D>> <> " Active\"}}]}\n\n"

      chunk(conn, chunk_2)
      Process.sleep(10)

      chunk(conn, "data: [DONE]\n\n")
      conn
    end

    defp handle_openai_completion(conn, :rate_limit_429, _server_pid) do
      conn
      |> put_resp_header("retry-after", "1")
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{"error" => %{"message" => "Rate limit exceeded. Please retry later."}})
      )
    end

    defp handle_openai_completion(conn, :server_error_500, _server_pid) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(500, Jason.encode!(%{"error" => %{"message" => "Internal server error."}}))
    end

    defp handle_openai_completion(
           conn,
           {:retry_then_succeed, max_fails, success_scenario},
           server_pid
         ) do
      attempt = IexCode.E2E.MockLLMServer.increment_attempt(server_pid, "openai_chat")

      if attempt <= max_fails do
        conn
        |> put_resp_header("retry-after", "1")
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{"error" => %{"message" => "Transient error, attempt #{attempt}"}})
        )
      else
        handle_openai_completion(conn, success_scenario, server_pid)
      end
    end

    defp handle_openai_completion(conn, other, _server_pid) when is_function(other, 1) do
      other.(conn)
    end

    defp handle_openai_completion(conn, _other, _server_pid) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"choices" => [%{"message" => %{"content" => "Default mock response"}}]})
      )
    end

    # --- Scenario Handlers for Anthropic ---

    defp handle_anthropic_message(conn, :rate_limit_429, _server_pid) do
      conn
      |> put_resp_header("retry-after", "1")
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{
          "error" => %{"type" => "rate_limit_error", "message" => "Rate limit reached"}
        })
      )
    end

    defp handle_anthropic_message(conn, :server_error_500, _server_pid) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        500,
        Jason.encode!(%{"error" => %{"type" => "api_error", "message" => "Internal error"}})
      )
    end

    defp handle_anthropic_message(
           conn,
           {:retry_then_succeed, max_fails, success_scenario},
           server_pid
         ) do
      attempt = IexCode.E2E.MockLLMServer.increment_attempt(server_pid, "anthropic_msg")

      if attempt <= max_fails do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          500,
          Jason.encode!(%{"error" => %{"message" => "Transient error #{attempt}"}})
        )
      else
        handle_anthropic_message(conn, success_scenario, server_pid)
      end
    end

    defp handle_anthropic_message(conn, {:tool_call, tool_name, args}, _server_pid) do
      resp_body = %{
        "id" => "msg_mock_tool",
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_#{Ecto.UUID.generate()}",
            "name" => to_string(tool_name),
            "input" => if(is_binary(args), do: Jason.decode!(args), else: args)
          }
        ],
        "stop_reason" => "tool_use"
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp_body))
    end

    defp handle_anthropic_message(conn, _scenario, _server_pid) do
      resp_body = %{
        "id" => "msg_mock_#{System.unique_integer([:positive])}",
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "Anthropic response completed successfully."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 15, "output_tokens" => 25}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp_body))
    end
  end
end
