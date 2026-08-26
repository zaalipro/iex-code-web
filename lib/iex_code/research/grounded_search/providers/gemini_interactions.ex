defmodule IexCode.Research.GroundedSearch.Providers.GeminiInteractions do
  @moduledoc """
  Gemini Interactions API adapter for the hosted `google_search` tool.

  The Interactions API is beta. Requests pin the documented `Api-Revision`
  schema so an upstream breaking revision fails visibly instead of being
  heuristically reinterpreted.
  """
  @behaviour IexCode.Research.GroundedSearch.Provider

  alias IexCode.Research.GroundedSearch.{HTTP, Normalizer, ResponseHelpers}

  @endpoint "https://generativelanguage.googleapis.com/v1beta/interactions"
  @api_revision "2026-05-20"

  @impl true
  def id, do: :gemini_interactions

  @impl true
  def answer(query, opts) do
    result =
      with {:ok, query} <- Normalizer.query(query),
           {:ok, api_key, model} <- Normalizer.credentials(opts),
           {:ok, response} <- request(query, api_key, model, opts),
           :ok <- complete?(response),
           :ok <- search_errors(response),
           :ok <- validate_timeline(response),
           {:ok, normalized} <- normalize(response) do
        {:ok, normalized}
      end

    HTTP.sanitize_result(result, opts[:api_key])
  end

  defp request(query, api_key, model, opts) do
    body = %{"model" => model, "input" => query, "tools" => [%{"type" => "google_search"}]}

    HTTP.post(
      id(),
      @endpoint,
      api_key,
      [
        headers: [
          {"x-goog-api-key", api_key},
          {"api-revision", @api_revision},
          {"content-type", "application/json"}
        ],
        json: body
      ],
      opts
    )
  end

  defp complete?(%{"error" => error}) when not is_nil(error),
    do: {:error, {:provider_error, error}}

  defp complete?(%{"status" => status}) when status in ["failed", "cancelled", "incomplete"],
    do: {:error, {:incomplete, status}}

  defp complete?(_response), do: :ok

  defp search_errors(response) do
    response
    |> Map.get("steps", [])
    |> Normalizer.list()
    |> Enum.find_value(:ok, fn step ->
      if Normalizer.value(step, :type) == "google_search_result" and search_error?(step) do
        detail = Normalizer.value(step, :error) || :tool_reported_error
        {:error, {:provider_error, {:google_search, detail}}}
      end
    end)
  end

  defp search_error?(step) do
    Normalizer.value(step, :is_error) == true or is_map(Normalizer.value(step, :error))
  end

  defp validate_timeline(response) do
    steps = Normalizer.list(response["steps"])

    call_ids =
      steps
      |> Enum.filter(&(Normalizer.value(&1, :type) == "google_search_call"))
      |> Enum.map(&Normalizer.value(&1, :id))

    result_ids =
      steps
      |> Enum.filter(&(Normalizer.value(&1, :type) == "google_search_result"))
      |> Enum.map(&Normalizer.value(&1, :call_id))

    if call_ids != [] and
         Enum.all?(call_ids, &(is_binary(&1) and &1 != "" and &1 in result_ids)),
       do: :ok,
       else: {:error, {:invalid_response, :unmatched_google_search_call}}
  end

  defp normalize(response) do
    steps = Normalizer.list(response["steps"])

    output_groups =
      steps
      |> Enum.filter(&(Normalizer.value(&1, :type) == "model_output"))
      |> Enum.map(&Normalizer.value(&1, :content))

    {answer, citations} =
      ResponseHelpers.answer_and_citations(output_groups, "text", :annotations, :bytes)

    calls =
      steps
      |> Enum.filter(&(Normalizer.value(&1, :type) == "google_search_call"))
      |> Enum.map(fn call ->
        arguments = Normalizer.value(call, :arguments) || %{}

        %{
          id: Normalizer.value(call, :id),
          queries: Normalizer.list(Normalizer.value(arguments, :queries)),
          status: "completed",
          metadata: %{}
        }
      end)

    usage = response["usage"] || response["usage_metadata"] || %{}

    Normalizer.build(id(), answer, citations, calls, usage, %{
      "interaction_id" => response["id"],
      "model" => response["model"],
      "status" => response["status"],
      "api_revision" => @api_revision,
      "lifecycle" => "beta"
    })
  end
end
