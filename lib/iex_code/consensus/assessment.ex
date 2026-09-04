defmodule IexCode.Consensus.Assessment do
  @moduledoc """
  Structured code assessment from an individual reviewer (Cloud or Local model).
  Includes vote (:approve, :reject, :request_changes), confidence, dimensional scores,
  verdict reasoning, critique points, and suggested modifications.
  """

  @enforce_keys [:vote, :confidence]
  defstruct [
    :reviewer_id,
    :provider,
    :model,
    :vote,
    :confidence,
    scores: %{
      correctness: 0.8,
      security: 0.8,
      architectural_fit: 0.8,
      maintainability: 0.8,
      testability: 0.8
    },
    verdict_reason: "",
    critique_points: [],
    suggested_modifications: []
  ]

  @type vote :: :approve | :reject | :request_changes
  @type t :: %__MODULE__{
          reviewer_id: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          vote: vote(),
          confidence: float(),
          scores: %{
            correctness: float(),
            security: float(),
            architectural_fit: float(),
            maintainability: float(),
            testability: float()
          },
          verdict_reason: String.t(),
          critique_points: [map()],
          suggested_modifications: [String.t()]
        }

  @doc """
  Parses a JSON string, a markdown-wrapped codeblock, or a map into an Assessment struct.
  """
  @spec parse(String.t() | map()) :: {:ok, t()} | {:error, term()}
  def parse(input) when is_binary(input) do
    cleaned = extract_json(input)

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) ->
        parse(map)

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  def parse(%{} = map) do
    vote = normalize_vote(map["vote"] || map[:vote])
    confidence = parse_float(map["confidence"] || map[:confidence], 1.0)

    raw_scores = map["scores"] || map[:scores] || %{}

    scores = %{
      correctness: parse_float(raw_scores["correctness"] || raw_scores[:correctness], 0.8),
      security: parse_float(raw_scores["security"] || raw_scores[:security], 0.8),
      architectural_fit:
        parse_float(raw_scores["architectural_fit"] || raw_scores[:architectural_fit], 0.8),
      maintainability:
        parse_float(raw_scores["maintainability"] || raw_scores[:maintainability], 0.8),
      testability: parse_float(raw_scores["testability"] || raw_scores[:testability], 0.8)
    }

    critique_points =
      (map["critique_points"] || map[:critique_points] || [])
      |> Enum.map(&normalize_critique/1)

    suggested_modifications =
      map["suggested_modifications"] || map[:suggested_modifications] || []

    assessment = %__MODULE__{
      reviewer_id: map["reviewer_id"] || map[:reviewer_id],
      provider: map["provider"] || map[:provider],
      model: map["model"] || map[:model],
      vote: vote,
      confidence: confidence,
      scores: scores,
      verdict_reason: map["verdict_reason"] || map[:verdict_reason] || "",
      critique_points: critique_points,
      suggested_modifications: suggested_modifications
    }

    {:ok, assessment}
  rescue
    e -> {:error, e}
  end

  def to_map(%__MODULE__{} = a) do
    %{
      "reviewer_id" => a.reviewer_id,
      "provider" => a.provider,
      "model" => a.model,
      "vote" => to_string(a.vote),
      "confidence" => a.confidence,
      "scores" => a.scores,
      "verdict_reason" => a.verdict_reason,
      "critique_points" => a.critique_points,
      "suggested_modifications" => a.suggested_modifications
    }
  end

  defp extract_json(str) do
    str = String.trim(str)

    cond do
      Regex.match?(~r/```(?:json)?\s*([\s\S]*?)\s*```/i, str) ->
        [_, json] = Regex.run(~r/```(?:json)?\s*([\s\S]*?)\s*```/i, str)
        String.trim(json)

      String.starts_with?(str, "{") and String.ends_with?(str, "}") ->
        str

      true ->
        case {String.split(str, "{", parts: 2), String.split(str, "}")} do
          {[_, rest], _} ->
            "{" <> Enum.join(Enum.slice(String.split(rest, "}"), 0..-2//1), "}") <> "}"

          _ ->
            str
        end
    end
  end

  defp normalize_vote(v) when v in [:approve, "approve", "approved"], do: :approve
  defp normalize_vote(v) when v in [:reject, "reject", "rejected"], do: :reject

  defp normalize_vote(v) when v in [:request_changes, "request_changes", "changes_requested"],
    do: :request_changes

  defp normalize_vote(_), do: :request_changes

  defp parse_float(num, _default) when is_float(num), do: num
  defp parse_float(num, _default) when is_integer(num), do: num * 1.0

  defp parse_float(str, default) when is_binary(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp normalize_critique(%{} = c) do
    severity =
      case c["severity"] || c[:severity] do
        s when s in [:blocker, "blocker"] -> :blocker
        s when s in [:minor, "minor"] -> :minor
        s when s in [:major, "major"] -> :major
        _ -> :minor
      end

    %{
      severity: severity,
      category: c["category"] || c[:category] || "general",
      file_path: c["file_path"] || c[:file_path],
      line_number: c["line_number"] || c[:line_number],
      description: c["description"] || c[:description] || ""
    }
  end

  defp normalize_critique(other), do: other
end
