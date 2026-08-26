defmodule IexCode.Research.DagStepHandlers.ReportVerify do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.{DagContracts, Report}

  @fields ~w(max_input_tokens max_output_tokens max_cost_cents require_sentence_level_citations reject_missing_evidence_hashes reject_fabricated_urls artifact_kind level_policy)

  @impl true
  def descriptor do
    %{
      kind: "research_report_verify",
      version: 1,
      effect_class: :pure,
      replay_policy: :safe,
      resource_contract: "research_evidence_read_v1",
      checkpoint_version: 1,
      max_output_bytes: 240_000,
      default_timeout_ms: 30_000
    }
  end

  @impl true
  def validate_params(params, dependencies) when length(dependencies) == 2 do
    with :ok <- DagContracts.exact_fields(params, @fields),
         :ok <- DagContracts.integer(params["max_input_tokens"], 256..200_000, :input_tokens),
         :ok <- DagContracts.integer(params["max_output_tokens"], 256..32_000, :output_tokens),
         :ok <- DagContracts.integer(params["max_cost_cents"], 0..100_000, :cost),
         true <- params["require_sentence_level_citations"] or {:error, {:params, :citations}},
         true <- params["reject_missing_evidence_hashes"] or {:error, {:params, :hashes}},
         true <- params["reject_fabricated_urls"] or {:error, {:params, :urls}},
         :ok <- DagContracts.level_policy(params["level_policy"]),
         true <-
           params["artifact_kind"] == "research_verified_report" or
             {:error, {:params, :artifact_kind}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  def validate_params(_params, _dependencies),
    do: {:error, :verification_requires_draft_and_audit}

  @impl true
  def execute(params, context) do
    with false <- DagContracts.cancelled?(context),
         {:ok, draft} <- DagContracts.dependency(context, "research.report_draft"),
         {:ok, audit} <- DagContracts.dependency(context, "research.audit"),
         draft_data <- DagContracts.data(draft),
         audit_data <- DagContracts.data(audit),
         sources when is_list(sources) and sources != [] <- audit_data["sources"],
         :ok <- conflict_audit_complete(audit_data),
         :ok <- evidence_ids_present(sources, audit_data["claims"]),
         :ok <- evidence_hashes_present(sources, params["reject_missing_evidence_hashes"]),
         :ok <-
           sentence_citations(draft_data["markdown"], params["require_sentence_level_citations"]),
         :ok <-
           source_urls_only(draft_data["markdown"], sources, params["reject_fabricated_urls"]),
         {:ok, markdown} <-
           Report.ensure_citations(draft_data["markdown"], report_sources(sources)) do
      DagContracts.wrap("research.verified_report", "research_verified_report", %{
        "markdown" => markdown,
        "sources" => compact_sources(sources),
        "claims" => audit_data["claims"],
        "gaps" => audit_data["gaps"],
        "verified" => true,
        "verification" => %{
          "citation_syntax" => "verified",
          "evidence_identity" => "verified",
          "claim_entailment" => "not_automatically_proven",
          "conflict_audit" => audit_data["conflict_audit"]
        }
      })
    else
      true -> {:error, :cancelled}
      nil -> {:error, :invalid_verification_input}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_verification_input}
    end
  end

  defp conflict_audit_complete(%{
         "conflict_audit" => %{"required" => required, "checked" => true} = audit,
         "claims" => claims
       })
       when is_boolean(required) and is_list(claims) do
    valid_conflicts? =
      is_integer(audit["conflict_count"]) and audit["conflict_count"] >= 0 and
        is_list(audit["conflicts"])

    claims_checked? = not required or Enum.all?(claims, &(&1["conflict_checked"] == true))

    if valid_conflicts? and claims_checked?, do: :ok, else: {:error, :conflict_audit_incomplete}
  end

  defp conflict_audit_complete(_audit_data), do: {:error, :conflict_audit_incomplete}

  defp evidence_ids_present(sources, claims) when is_list(claims) do
    source_ids = Enum.map(sources, & &1["id"])
    ids = MapSet.new(source_ids)

    valid_sources? =
      length(source_ids) == MapSet.size(ids) and
        Enum.all?(sources, fn source ->
          canonical = canonical_url(source["url"])

          valid_digest?(source["id"]) and canonical != "" and
            source["id"] == sha256(canonical)
        end)

    if valid_sources? and
         Enum.all?(claims, fn claim ->
           ids_for_claim = Map.get(claim, "evidence_ids", [])
           ids_for_claim != [] and Enum.all?(ids_for_claim, &MapSet.member?(ids, &1))
         end) do
      :ok
    else
      {:error, :claim_evidence_missing}
    end
  end

  defp evidence_ids_present(_sources, _claims), do: {:error, :invalid_claim_ledger}

  defp evidence_hashes_present(_sources, false), do: :ok

  defp evidence_hashes_present(sources, true) do
    if Enum.all?(sources, fn source ->
         case Map.get(source, "content_hash") do
           "sha256:" <> digest -> valid_digest?(digest)
           _missing_or_invalid -> false
         end
       end),
       do: :ok,
       else: {:error, :evidence_hash_missing}
  end

  defp sentence_citations(_markdown, false), do: :ok

  defp sentence_citations(markdown, true) when is_binary(markdown) do
    uncited =
      markdown
      |> strip_code()
      |> String.split("\n")
      |> Enum.reject(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or String.starts_with?(trimmed, "#")
      end)
      |> Enum.flat_map(&sentences/1)
      |> Enum.count(fn sentence ->
        Regex.match?(~r/[[:alpha:]]/u, sentence) and not Regex.match?(~r/\[\d+\]/, sentence)
      end)

    if uncited == 0, do: :ok, else: {:error, {:uncited_research_sentences, uncited}}
  end

  defp sentence_citations(_markdown, true), do: {:error, :invalid_research_report}

  defp source_urls_only(_markdown, _sources, false), do: :ok

  defp source_urls_only(markdown, sources, true) when is_binary(markdown) do
    allowed = sources |> Enum.map(&canonical_url(&1["url"])) |> MapSet.new()

    invalid =
      markdown
      |> strip_code()
      |> extract_urls()
      |> Enum.reject(&MapSet.member?(allowed, canonical_url(&1)))
      |> Enum.uniq()

    if invalid == [], do: :ok, else: {:error, :fabricated_research_url}
  end

  defp source_urls_only(_markdown, _sources, true), do: {:error, :invalid_research_report}

  defp strip_code(markdown) do
    markdown
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/`[^`\n]*`/, "")
  end

  defp sentences(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\s*(?:[-*+] |\d+[.)] )/u, "")
    |> String.split(~r/(?<=[.!?])\s+/u, trim: true)
  end

  defp extract_urls(markdown) do
    ~r/https?:\/\/[^\s<>\]\["']+/u
    |> Regex.scan(markdown)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, ".,;:!?)"))
  end

  defp canonical_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      %URI{
        uri
        | scheme: String.downcase(uri.scheme),
          host: String.downcase(uri.host),
          fragment: nil
      }
      |> URI.to_string()
      |> String.trim_trailing("/")
    else
      ""
    end
  end

  defp canonical_url(_url), do: ""

  defp valid_digest?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp valid_digest?(_value), do: false

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp report_sources(sources) do
    Enum.map(sources, fn source ->
      %{
        title: source["title"],
        url: source["url"],
        provider: source["provider"],
        snippet: source["snippet"]
      }
    end)
  end

  defp compact_sources(sources) do
    Enum.map(sources, fn source ->
      Map.take(source, ~w(id url title provider plane provenance content_hash))
    end)
  end
end
