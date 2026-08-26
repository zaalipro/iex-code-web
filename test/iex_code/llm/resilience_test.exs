defmodule IexCode.LLM.ResilienceTest do
  use ExUnit.Case, async: false
  alias IexCode.LLM.Resilience

  describe "with_retry/2" do
    test "retries on 429 status code and succeeds on subsequent attempt" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      flaky_fn = fn ->
        attempts = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

        if attempts < 3 do
          {:error, %{status: 429, message: "Rate limit exceeded"}}
        else
          {:ok, "Success after #{attempts} attempts"}
        end
      end

      assert {:ok, "Success after 3 attempts"} =
               Resilience.with_retry(flaky_fn,
                 max_retries: 4,
                 base_backoff_ms: 1,
                 max_backoff_ms: 5,
                 jitter: :none
               )

      assert Agent.get(counter, & &1) == 3
      Agent.stop(counter)
    end

    test "does not retry on non-retryable 401 status" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      auth_error_fn = fn ->
        Agent.update(counter, &(&1 + 1))
        {:error, %{status: 401, message: "Unauthorized"}}
      end

      assert {:error, %{status: 401}} =
               Resilience.with_retry(auth_error_fn,
                 max_retries: 3,
                 base_backoff_ms: 1
               )

      # Attempted only once
      assert Agent.get(counter, & &1) == 1
      Agent.stop(counter)
    end

    test "stops retrying after exceeding max_retries" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      always_fail_fn = fn ->
        Agent.update(counter, &(&1 + 1))
        {:error, %{status: 500, message: "Server Error"}}
      end

      assert {:error, %{status: 500}} =
               Resilience.with_retry(always_fail_fn,
                 max_retries: 2,
                 base_backoff_ms: 1,
                 jitter: :none
               )

      # Initial attempt (1) + 2 retries = 3 attempts total
      assert Agent.get(counter, & &1) == 3
      Agent.stop(counter)
    end
  end

  describe "with_fallback/2" do
    test "falls back to secondary provider when primary provider fails" do
      primary_fn = fn -> {:error, %{status: 404, message: "Model not found"}} end
      secondary_fn = fn -> {:ok, "Response from fallback"} end

      providers = [
        {"openai/gpt-4o", primary_fn},
        {"anthropic/claude", secondary_fn}
      ]

      assert {:ok, "Response from fallback",
              %{provider: "anthropic/claude", fallback_used?: true}} =
               Resilience.with_fallback(providers, max_retries: 1, base_backoff_ms: 1)
    end

    test "returns error if all providers fail" do
      p1 = fn -> {:error, "p1 failed"} end
      p2 = fn -> {:error, "p2 failed"} end

      providers = [
        {"p1", p1},
        {"p2", p2}
      ]

      assert {:error, {:all_providers_failed, errors}} =
               Resilience.with_fallback(providers, max_retries: 1, base_backoff_ms: 1)

      assert length(errors) == 2
      assert {"p1", "p1 failed"} in errors
      assert {"p2", "p2 failed"} in errors
    end
  end

  describe "compute_backoff/4" do
    test "computes deterministic exponential backoff when jitter is :none" do
      assert Resilience.compute_backoff(1, 100, 1000, :none) == 100
      assert Resilience.compute_backoff(2, 100, 1000, :none) == 200
      assert Resilience.compute_backoff(3, 100, 1000, :none) == 400
      assert Resilience.compute_backoff(4, 100, 1000, :none) == 800
      assert Resilience.compute_backoff(5, 100, 1000, :none) == 1000
    end

    test "computes bounded jitter backoff" do
      val = Resilience.compute_backoff(2, 100, 1000, :full)
      assert val >= 0 and val <= 200
    end
  end
end
