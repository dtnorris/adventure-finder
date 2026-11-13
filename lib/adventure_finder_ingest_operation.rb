# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  # Pure document/revision validation only: no persistence, artifact reads or routing.
  class IngestOperation
    VERSION = "adventurefinder-ingest-operation/v0.1"
    ROOTS = %w[input front_door pipeline converter source catalog].freeze
    SOURCE_CHOICES = %w[source_id edition pagination_authority publisher].freeze
    FUTURE_CHOICES = %w[boundaries parentage adventure_ids approval].freeze
    ARTIFACTS = {
      "conversion_receipt" => ["pdf-to-llm-md-converter", %w[pdf-to-llm-md/conversion-receipt/v0.1]],
      "source_intake" => ["af-data-pipeline", %w[af-source-intake/v0.1]],
      "boundary_dossier" => ["af-data-pipeline", %w[af-boundary-dossier/v0.1 af-boundary-dossier/v0.2]],
      "editorial_context" => ["af-data-pipeline", %w[af-boundary-editorial-context/v0.1]],
      "editorial_decisions" => [
        "af-data-pipeline",
        %w[af-boundary-editorial-decisions/v0.1 af-boundary-editorial-decisions/v0.2]
      ],
      "boundary_freeze" => ["af-data-pipeline", %w[af-boundary-freeze/v0.1]],
      "boundary_apply_report" => ["af-data-pipeline", %w[af-boundary-freeze-apply-report/v0.1]]
    }.freeze

    def self.validate!(document)
      new.validate!(document)
    end

    def self.validate_revision!(previous, current)
      new.validate_revision!(previous, current)
    end

    # Canonical, sorted-key compact JSON; never a digest of a filesystem path.
    def self.digest(document)
      Digest::SHA256.hexdigest(JSON.generate(canonical(document)))
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def validate!(doc)
      selected = doc.is_a?(Hash) && doc.key?("editorial_specifications")
      keys!(doc, %w[contract_version operation_id created_at revision previous_revision_sha256
                    input source_declaration base_catalog policy artifacts future_choices coordination] + (selected ? ["editorial_specifications"] : []))
      check!(doc["contract_version"] == VERSION, "unsupported operation contract_version")
      check!(doc["operation_id"].is_a?(String) && doc["operation_id"].match?(
        /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      ), "operation_id must be a lowercase UUIDv4")
      time!(doc["created_at"])
      check!(doc["revision"].is_a?(Integer) && doc["revision"] >= 0, "invalid revision")
      if doc["revision"].zero?
        check!(doc["previous_revision_sha256"].nil?, "initial revision has no predecessor")
      else
        sha!(doc["previous_revision_sha256"])
      end
      keys!(doc["input"], %w[kind content])
      check!(doc["input"]["kind"] == "digital_book_pdf", "unsupported input kind")
      content!(doc["input"]["content"])
      keys!(doc["source_declaration"], SOURCE_CHOICES)
      doc["source_declaration"].each_value { |choice| choice!(choice) unless choice.nil? }
      catalog!(doc["base_catalog"])
      policy!(doc["policy"]) unless doc["policy"].nil?
      keys!(doc["future_choices"], FUTURE_CHOICES)
      check!(doc["future_choices"].values.all?(&:nil?), "future choices belong to owner artifacts")
      artifacts!(doc["artifacts"])
      if doc.key?("editorial_specifications")
        binding = doc["editorial_specifications"]
        keys!(binding, %w[repository revision inventory_sha256 root files])
        text!(binding["repository"])
        check!(binding["revision"].is_a?(String) && /\A[0-9a-f]{40}\z/.match?(binding["revision"]), "invalid public revision")
        sha!(binding["inventory_sha256"])
        text!(binding["root"])
        check!(binding["root"].start_with?("/"), "public root must be absolute")
        check!(binding["files"].is_a?(Array) && binding["files"].length == 2, "expected two public definitions")
        binding["files"].each do |file|
          keys!(file, %w[filename version status sha256 path bytes])
          %w[filename version status path].each { |key| text!(file[key]) }
          sha!(file["sha256"])
          check!(file["bytes"].is_a?(Integer) && file["bytes"] > 0, "invalid public definition size")
        end
      end
      coordination!(doc)
      if doc["revision"].zero?
        check!(doc["artifacts"].empty? && doc["coordination"]["status"] == "created",
               "initial operation must be created with no artifacts")
      end
      true
    end

    def validate_revision!(previous, current)
      validate!(previous)
      validate!(current)
      # Ruby considers 1 == 1.0; the canonical document identity does not.
      return true if self.class.digest(previous) == self.class.digest(current)

      check!(current["revision"] == previous["revision"] + 1, "revision must advance by one")
      check!(current["previous_revision_sha256"] == self.class.digest(previous), "wrong predecessor")
      %w[contract_version operation_id created_at input base_catalog].each do |key|
        check!(identity(previous[key]) == identity(current[key]), "immutable #{key} changed")
      end
      SOURCE_CHOICES.each do |key|
        old = previous["source_declaration"][key]
        check!(old.nil? || old == current["source_declaration"][key], "bound source #{key} changed")
      end
      check!(previous["policy"].nil? || self.class.digest(previous["policy"]) ==
             self.class.digest(current["policy"]), "bound policy changed")
      if previous.key?("editorial_specifications")
        check!(previous["editorial_specifications"] == current["editorial_specifications"],
               "bound editorial specifications changed")
      elsif current.key?("editorial_specifications")
        check!(previous["artifacts"].none? { |artifact| %w[editorial_context editorial_decisions boundary_freeze].include?(artifact["kind"]) },
               "historical editorial selection cannot be replaced; create a new operation")
      end
      old_refs = previous["artifacts"]
      check!(current["artifacts"].length >= old_refs.length, "bound artifact removed")
      old_refs.each_with_index do |ref, index|
        check!(identity(ref) == identity(current["artifacts"][index]), "bound artifact changed")
      end
      if previous["coordination"]["status"] == "closed"
        raise Error, "closed operations cannot advance; create a new operation"
      end
      true
    end

    # Observation basis excludes locators and administrative/replay metadata.
    def self.observation_basis(document)
      new.observation_basis(document)
    end

    def observation_basis(doc)
      basis = identity(doc.slice("operation_id", "input", "source_declaration", "base_catalog", "artifacts"))
      basis["editorial_specifications"] = doc["editorial_specifications"] if doc.key?("editorial_specifications")
      self.class.digest(basis.merge("policy" => doc["policy"]))
    end

    private

    def check!(condition, message)
      raise Error, message unless condition
    end

    def keys!(value, expected)
      check!(value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } &&
             value.keys.sort == expected.sort, "expected exactly: #{expected.join(', ')}")
    end

    def text!(value)
      check!(value.is_a?(String) && !value.empty? && value == value.strip &&
             !value.match?(/[[:cntrl:]]/), "expected nonempty trimmed text")
    end

    def sha!(value)
      check!(value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/), "expected lowercase SHA-256")
    end

    def time!(value)
      check!(value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/),
             "expected UTC timestamp with seconds")
      check!(Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ") == value, "invalid timestamp")
    rescue ArgumentError
      raise Error, "invalid timestamp"
    end

    def content!(value)
      keys!(value, %w[sha256 bytes locator])
      sha!(value["sha256"])
      check!(value["bytes"].is_a?(Integer) && value["bytes"] > 0, "bytes must be positive")
      locator = value["locator"]
      keys!(locator, %w[root path])
      check!(ROOTS.include?(locator["root"]), "unknown locator root")
      path = locator["path"]
      text!(path)
      check!(!path.start_with?("/") && !path.include?("\\") && !path.include?(":") &&
             path.split("/", -1).none? { |part| ["", ".", ".."].include?(part) }, "unsafe relative path")
    end

    def choice!(choice)
      keys!(choice, %w[value selected_by selected_at])
      text!(choice["value"])
      text!(choice["selected_by"])
      time!(choice["selected_at"])
    end

    def catalog!(catalog)
      keys!(catalog, %w[content selection])
      content!(catalog["content"])
      selection = catalog["selection"]
      keys!(selection, %w[method selected_by selected_at project_state])
      text!(selection["selected_by"])
      time!(selection["selected_at"])
      case selection["method"]
      when "explicit"
        check!(selection["project_state"].nil?, "explicit selection has no catalog_head provenance")
      when "catalog_head"
        state = selection["project_state"]
        keys!(state, %w[contract_version content])
        check!(state["contract_version"] == "adventurefinder-project-state/v0.2", "unsupported project state")
        content!(state["content"])
      else
        raise Error, "unsupported catalog selection"
      end
    end

    def policy!(policy)
      keys!(policy, %w[policy_id policy_version definition_sha256 selected_values selected_by selected_at])
      %w[policy_id policy_version selected_by].each { |key| text!(policy[key]) }
      sha!(policy["definition_sha256"])
      time!(policy["selected_at"])
      check!(policy["selected_values"].is_a?(Hash) && !policy["selected_values"].empty?, "missing policy values")
      json_value!(policy["selected_values"])
    end

    def json_value!(value)
      case value
      when Hash
        value.each { |key, item| text!(key); json_value!(item) }
      when Array then value.each { |item| json_value!(item) }
      when String, Integer, TrueClass, FalseClass, NilClass then nil
      when Float then check!(value.finite?, "non-finite policy value")
      else raise Error, "policy values must be JSON"
      end
    end

    def artifacts!(refs)
      check!(refs.is_a?(Array), "artifacts must be an array")
      ids = %w[input base_catalog]
      latest = {}
      refs.each do |ref|
        keys!(ref, %w[artifact_id kind owner contract_version content inputs supersedes])
        text!(ref["artifact_id"])
        check!(!ids.include?(ref["artifact_id"]), "duplicate/reserved artifact_id")
        spec = ARTIFACTS[ref["kind"]]
        check!(spec && spec[0] == ref["owner"] && spec[1].include?(ref["contract_version"]),
               "unsupported artifact kind, owner or version")
        content!(ref["content"])
        inputs = ref["inputs"]
        check!(inputs.is_a?(Array) && !inputs.empty? && inputs.uniq == inputs &&
               inputs.all? { |id| ids.include?(id) }, "inputs must name distinct earlier bindings")
        check!(ref["supersedes"] == latest[ref["kind"]], "conflicting artifact lineage")
        latest[ref["kind"]] = ref["artifact_id"]
        ids << ref["artifact_id"]
      end
    end

    def coordination!(doc)
      coordination = doc["coordination"]
      keys!(coordination, %w[status route_observation])
      status = coordination["status"]
      check!(%w[created open paused closed].include?(status), "unsupported coordination status")
      check!(status != "created" || doc["artifacts"].empty?, "created operation already has artifacts")
      check!(status != "open" || !doc["artifacts"].empty?, "open operation needs a bound artifact")
      observation = coordination["route_observation"]
      return if observation.nil?

      keys!(observation, %w[artifact_id router_state observed_at basis_sha256])
      check!(doc["artifacts"].any? { |ref| ref["artifact_id"] == observation["artifact_id"] },
             "observation must reference a bound artifact")
      text!(observation["router_state"])
      time!(observation["observed_at"])
      check!(observation["basis_sha256"] == observation_basis(doc), "stale observation basis")
    end

    # Called only for contract-defined input/catalog/artifact subtrees, never policy.
    def identity(value)
      case value
      when Hash
        content = value.keys.sort == %w[bytes locator sha256]
        value.reject { |key, _| content && key == "locator" }
             .to_h { |key, item| [key, identity(item)] }
      when Array then value.map { |item| identity(item) }
      else value
      end
    end
  end
end
