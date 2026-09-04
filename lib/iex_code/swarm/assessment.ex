defmodule IexCode.Swarm.Assessment do
  @moduledoc """
  Structured code assessment from a swarm reviewer (Auditor, Architect, Verifier).
  Includes vote (:approve, :reject, :request_changes), confidence [0.0, 1.0],
  5-dimensional scores, verdict reasoning, critique points, and suggested modifications.
  """

  @derive Jason.Encoder
  @enforce_keys [:id, :proposal_id, :reviewer_id, :vote, :confidence]
  defstruct [
    :id,
    :proposal_id,
    :reviewer_id,
    role: :auditor,
    model_provider: "anthropic",
    model_id: "claude-3-7-sonnet",
    provider: nil,
    model: nil,
    vote: :approve,
    confidence: 1.0,
    scores: %{
      syntax: 0.8,
      correctness: 0.8,
      security: 0.8,
      architectural_fit: 0.8,
      maintainability: 0.8,
      testability: 0.8
    },
    verdict_reason: "",
    critique_points: [],
    suggested_modifications: [],
    timestamp: nil
  ]

  @type vote :: :approve | :reject | :request_changes

  @type t :: %__MODULE__{
          id: String.t(),
          proposal_id: String.t(),
          reviewer_id: String.t(),
          role: atom(),
          model_provider: String.t(),
          model_id: String.t(),
          provider: String.t() | nil,
          model: String.t() | nil,
          vote: vote(),
          confidence: float(),
          scores: map(),
          verdict_reason: String.t(),
          critique_points: [map()],
          suggested_modifications: [String.t()],
          timestamp: DateTime.t() | nil
        }

  @doc """
  Constructs a new Assessment struct with attribute normalization.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    id = get_val(attrs, :id) || generate_id()
    proposal_id = to_string(get_val(attrs, :proposal_id) || "default-proposal")
    reviewer_id = to_string(get_val(attrs, :reviewer_id) || "reviewer-1")
    role = normalize_atom(get_val(attrs, :role) || :auditor)

    provider =
      to_string(get_val(attrs, :model_provider) || get_val(attrs, :provider) || "anthropic")

    model =
      to_string(get_val(attrs, :model_id) || get_val(attrs, :model) || "claude-3-7-sonnet")

    vote = normalize_vote(get_val(attrs, :vote))
    confidence = clamp_float(get_val(attrs, :confidence, 1.0), 0.0, 1.0)
    scores = normalize_scores(get_val(attrs, :scores))
    verdict_reason = to_string(get_val(attrs, :verdict_reason) || "")
    critique_points = normalize_critiques(get_val(attrs, :critique_points) || [])
    suggested_mods = normalize_string_list(get_val(attrs, :suggested_modifications) || [])
    timestamp = get_val(attrs, :timestamp) || DateTime.utc_now()

    %__MODULE__{
      id: to_string(id),
      proposal_id: proposal_id,
      reviewer_id: reviewer_id,
      role: role,
      model_provider: provider,
      model_id: model,
      provider: provider,
      model: model,
      vote: vote,
      confidence: confidence,
      scores: scores,
      verdict_reason: verdict_reason,
      critique_points: critique_points,
      suggested_modifications: suggested_mods,
      timestamp: timestamp
    }
  end

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

  def parse(map) when is_map(map) do
    {:ok, new(map)}
  rescue
    e -> {:error, {:assessment_parse_failed, Exception.message(e)}}
  end

  defp extract_json(text) do
    trimmed = String.trim(text)

    cond do
      Regex.run(~r/```(?:json)?\s*([\s\S]*?)\s*```/, trimmed) ->
        [_, json_body] = Regex.run(~r/```(?:json)?\s*([\s\S]*?)\s*```/, trimmed)
        String.trim(json_body)

      true ->
        trimmed
    end
  end

  defp generate_id do
    "asmt-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp normalize_vote(:approve), do: :approve
  defp normalize_vote("approve"), do: :approve
  defp normalize_vote(:reject), do: :reject
  defp normalize_vote("reject"), do: :reject
  defp normalize_vote(:request_changes), do: :request_changes
  defp normalize_vote("request_changes"), do: :request_changes
  defp normalize_vote(_), do: :request_changes

  defp normalize_scores(nil) do
    %{
      syntax: 0.8,
      correctness: 0.8,
      security: 0.8,
      architectural_fit: 0.8,
      maintainability: 0.8,
      testability: 0.8
    }
  end

  defp normalize_scores(map) when is_map(map) do
    defaults = %{
      syntax: 0.8,
      correctness: 0.8,
      security: 0.8,
      architectural_fit: 0.8,
      maintainability: 0.8,
      testability: 0.8
    }

    Enum.reduce(defaults, %{}, fn {dim, def_val}, acc ->
      val =
        Map.get(map, dim) ||
          Map.get(map, to_string(dim)) ||
          case dim do
            :architectural_fit -> Map.get(map, :architecture) || Map.get(map, "architecture")
            :syntax -> Map.get(map, :code_quality) || Map.get(map, "code_quality")
            _ -> nil
          end || def_val

      Map.put(acc, dim, clamp_float(val, 0.0, 1.0))
    end)
  end

  defp normalize_critiques(list) when is_list(list) do
    Enum.map(list, fn
      map when is_map(map) ->
        severity =
          case Map.get(map, :severity) || Map.get(map, "severity") do
            s when s in [:blocker, "blocker"] -> :blocker
            s when s in [:major, "major"] -> :major
            _ -> :minor
          end

        %{
          severity: severity,
          category: to_string(Map.get(map, :category) || Map.get(map, "category") || "general"),
          file_path: Map.get(map, :file_path) || Map.get(map, "file_path"),
          line_number: Map.get(map, :line_number) || Map.get(map, "line_number"),
          description: to_string(Map.get(map, :description) || Map.get(map, "description") || "")
        }

      other ->
        %{
          severity: :minor,
          category: "general",
          file_path: nil,
          line_number: nil,
          description: inspect(other)
        }
    end)
  end

  defp normalize_critiques(_), do: []

  defp normalize_string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_string_list(_), do: []

  defp clamp_float(val, min_v, max_v) when is_number(val) do
    cond do
      val < min_v -> min_v * 1.0
      val > max_v -> max_v * 1.0
      true -> val * 1.0
    end
  end

  defp clamp_float(_, min_v, _max_v), do: min_v * 1.0

  defp get_val(map, key, default \\ nil) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      nil -> default
      val -> val
    end
  end

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> :auditor
    end
  end

  defp normalize_atom(_), do: :auditor
end
