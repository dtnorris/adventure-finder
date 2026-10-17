# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "yaml"

module AdventureFinderWorkspace
  PRODUCTION_CONTEXT_SCHEMA_VERSION = "adventurefinder-production-context/v0.1"

  # Portable batch/fleet authority loaded from a strict YAML registry. Resolves
  # registered paths and verifies pinned artifacts; invalid authority raises Error.
  class ProductionContextRegistry
    HANDLE_TYPES = %w[batch fleet].freeze
    WORKER_SOURCE_TYPES = %w[local remote].freeze
    PATH_FIELDS = {
      "batch" => %w[
        afw.repository_root afw.workload_root afw.plan_path
        wlo.repository_root wlo.output_root local_workers.repository_root
      ],
      "fleet" => %w[
        rpof.repository_root rpof.campaign_path rpof.budget_path
        rpof.state_root rpof.binding_path
      ]
    }.freeze
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    CAMPAIGN_KEYS = %w[
      contract_version campaign_id max_workers max_hourly_rate_usd profiles
    ].freeze
    PROFILE_KEYS = %w[
      profile_id model expected_digest required_context_length
      require_fully_gpu_resident min_workers desired_workers max_workers
    ].freeze
    IDENTITY_KEYS = %w[
      contract_version campaign_id campaign_sha256 hardware_qualification_sha256
    ].freeze
    BUDGET_KEYS = %w[
      contract_version campaign_identity campaign_identity_sha256 budget_id
      max_cumulative_compute_usd max_aggregate_hourly_rate_usd max_workers
      max_runtime_seconds guardian_poll_seconds
      orchestrator_heartbeat_timeout_seconds teardown_reserve_seconds
    ].freeze

    attr_reader :path, :data, :workspace_root

    # Load context authority from YAML beneath the supplied portable workspace.
    # Returns a validated registry; missing files, ambiguous YAML or invalid
    # selections/policies raise Error before component execution.
    def initialize(path, workspace_root:)
      @path = Pathname(path).expand_path
      @workspace_root = Pathname(workspace_root).expand_path.cleanpath
      source = @path.read
      reject_duplicate_yaml_keys!(YAML.parse(source))
      @data = YAML.safe_load(source, permitted_classes: [], aliases: false)
      validate!
    rescue Errno::ENOENT
      raise Error, "production context registry not found: #{@path}"
    rescue Psych::SyntaxError => e
      raise Error, "invalid YAML in #{@path}: #{e.message}"
    end

    def resolve(type, name)
      type = type.to_s.downcase
      name = name.to_s
      raise Error, "context type must be batch or fleet" unless HANDLE_TYPES.include?(type)

      registered = data.fetch("contexts").fetch(type).fetch(name) do
        raise Error, "unknown production context: #{type} #{name}"
      end
      context = Marshal.load(Marshal.dump(registered))
      PATH_FIELDS.fetch(type).each do |field|
        next if field.start_with?("local_workers.") && !context.key?("local_workers")

        assign_nested(context, field, resolve_path(fetch_nested(context, field), "#{type} #{name}.#{field}").to_s)
      end
      {"handle" => "#{type} #{name}"}.merge(context)
    end

    def verify(type, name)
      type = type.to_s.downcase
      context = resolve(type, name)
      failures = []

      case type
      when "batch"
        verify_directory(context.dig("afw", "repository_root"), "AFW production root", failures)
        verify_directory(context.dig("afw", "workload_root"), "AFW workload root", failures)
        verify_file(context.dig("afw", "plan_path"), "AFW execution plan", failures)
        verify_directory(context.dig("wlo", "repository_root"), "WLO production root", failures)
        verify_directory(context.dig("wlo", "output_root"), "WLO output root", failures)
        sources = context.fetch("worker_sources", context.key?("local_workers") ? ["local"] : [])
        if sources.include?("local")
          verify_directory(context.dig("local_workers", "repository_root"), "LOW production root", failures)
        end
        verify_plan(context, failures)
      when "fleet"
        verify_directory(context.dig("rpof", "repository_root"), "RPOF production root", failures)
        verify_file(context.dig("rpof", "campaign_path"), "RPOF campaign", failures)
        verify_file(context.dig("rpof", "budget_path"), "RPOF budget", failures)
        verify_directory(context.dig("rpof", "state_root"), "RPOF state root", failures)
        verify_file(context.dig("rpof", "binding_path"), "RPOF durable campaign binding", failures)
        verify_fleet_identity(context, failures)
      end

      failures
    end

    private

    # Reject duplicate mapping keys before Psych discards their first values.
    # Takes a parsed YAML node, returns nil, and raises Error for ambiguity.
    def reject_duplicate_yaml_keys!(node)
      if node.is_a?(Psych::Nodes::Mapping)
        unless node.children.each_slice(2).all? { |key, _value| key.is_a?(Psych::Nodes::Scalar) }
          raise Error, "YAML mapping keys must be scalars in #{@path}"
        end
        keys = node.children.each_slice(2).map { |key, _value| key.value }
        raise Error, "duplicate YAML mapping key in #{@path}" unless keys.uniq == keys
      end
      node.children&.each { |child| reject_duplicate_yaml_keys!(child) } if node
      nil
    end

    def validate!
      raise Error, "production context registry must be a mapping" unless data.is_a?(Hash)
      unless data["schema_version"] == PRODUCTION_CONTEXT_SCHEMA_VERSION
        raise Error, "unsupported production context schema #{data['schema_version'].inspect}"
      end

      contexts = data["contexts"]
      raise Error, "contexts must be a mapping" unless contexts.is_a?(Hash)
      HANDLE_TYPES.each do |type|
        raise Error, "contexts.#{type} must be a mapping" unless contexts[type].is_a?(Hash)
      end

      contexts.fetch("batch").each { |name, context| validate_batch(name, context) }
      contexts.fetch("fleet").each { |name, context| validate_fleet(name, context) }
      validate_associations(contexts)
    end

    # Validate one named batch, including path, source and policy authority.
    # Returns nil or validation results; malformed authority raises Error.
    def validate_batch(name, context)
      require_mapping(context, "batch #{name}")
      require_string(context, "production_batch_id", "batch #{name}")
      require_nested_strings(context, "afw", %w[repository_root workload_root plan_path], "batch #{name}")
      require_nested_strings(context, "wlo", %w[repository_root output_root], "batch #{name}")
      require_nested_strings(context, "plan", %w[plan_id sha256], "batch #{name}")
      if context.key?("local_workers")
        require_nested_strings(context, "local_workers", %w[repository_root], "batch #{name}")
      end
      validate_sha256(context.dig("plan", "sha256"), "batch #{name} plan")
      validate_model_aliases(context.fetch("model_aliases"), "batch #{name}") if context.key?("model_aliases")
      path_fields = PATH_FIELDS.fetch("batch").reject do |field|
        field.start_with?("local_workers.") && !context.key?("local_workers")
      end
      validate_relative_paths(context, path_fields, "batch #{name}")
      require_string_array(context, "associated_fleets", "batch #{name}")
      validate_worker_source_policies(name, context) if context.key?("worker_source_policies")
      return unless context.key?("worker_sources")

      require_string_array(context, "worker_sources", "batch #{name}")
      sources = context.fetch("worker_sources")
      raise Error, "batch #{name}.worker_sources must not be empty" if sources.empty?
      unknown = sources - WORKER_SOURCE_TYPES
      raise Error, "batch #{name}.worker_sources contains unsupported values: #{unknown.join(', ')}" unless unknown.empty?
      if sources.include?("local") && !context.key?("local_workers")
        raise Error, "batch #{name}.worker_sources selects local without local_workers"
      end
      if sources.include?("remote") && context.fetch("associated_fleets").empty?
        raise Error, "batch #{name}.worker_sources selects remote without an associated fleet"
      end
    end

    # Validate explicit policy opt-in against the entire selected source list.
    # Returns nil; incomplete/extra names or non-contract policies raise Error.
    def validate_worker_source_policies(name, context)
      policies = context.fetch("worker_source_policies")
      label = "batch #{name}.worker_source_policies"
      require_mapping(policies, label)
      sources = context["worker_sources"]
      unless sources.is_a?(Array) && !sources.empty? && sources.all?(String) &&
             policies.keys.all?(String) && policies.keys.sort == sources.sort
        raise Error, "#{label} must exactly match explicit worker_sources"
      end
      unless policies.values.all? { |policy| %w[required optional].include?(policy) }
        raise Error, "#{label} policies must be required or optional"
      end
      nil
    end

    def validate_fleet(name, context)
      require_mapping(context, "fleet #{name}")
      require_string(context, "campaign_id", "fleet #{name}")
      require_nested_strings(
        context, "rpof",
        %w[repository_root campaign_path budget_path state_root binding_path],
        "fleet #{name}"
      )
      validate_relative_paths(context, PATH_FIELDS.fetch("fleet"), "fleet #{name}")
      require_string_array(context, "associated_batches", "fleet #{name}")
    end

    def validate_associations(contexts)
      contexts.fetch("batch").each do |batch_name, batch|
        batch.fetch("associated_fleets").each do |fleet_name|
          fleet = contexts.fetch("fleet")[fleet_name]
          raise Error, "batch #{batch_name} references unknown fleet #{fleet_name}" unless fleet
          unless fleet.fetch("associated_batches").include?(batch_name)
            raise Error, "batch #{batch_name} / fleet #{fleet_name} association is not reciprocal"
          end
        end
      end
      contexts.fetch("fleet").each do |fleet_name, fleet|
        fleet.fetch("associated_batches").each do |batch_name|
          batch = contexts.fetch("batch")[batch_name]
          raise Error, "fleet #{fleet_name} references unknown batch #{batch_name}" unless batch
          unless batch.fetch("associated_fleets").include?(fleet_name)
            raise Error, "fleet #{fleet_name} / batch #{batch_name} association is not reciprocal"
          end
        end
      end
    end

    def validate_relative_paths(context, fields, label)
      fields.each do |field|
        value = fetch_nested(context, field)
        candidate = Pathname(value)
        components = candidate.each_filename.to_a
        if candidate.absolute? || components.empty? || components.include?("..") || candidate.cleanpath.to_s == "."
          raise Error, "#{label}.#{field} must stay beneath the workspace root"
        end
      end
    end

    def resolve_path(value, label)
      resolved = (workspace_root / value).cleanpath
      prefix = "#{workspace_root}#{File::SEPARATOR}"
      unless resolved.to_s.start_with?(prefix)
        raise Error, "#{label} resolves outside workspace root #{workspace_root}"
      end
      resolved
    end

    def fetch_nested(context, field)
      field.split(".").reduce(context) { |row, key| row.fetch(key) }
    end

    def assign_nested(context, field, value)
      keys = field.split(".")
      target = keys[0...-1].reduce(context) { |row, key| row.fetch(key) }
      target[keys.last] = value
    end

    def require_mapping(value, label)
      raise Error, "#{label} must be a mapping" unless value.is_a?(Hash)
    end

    def require_string(mapping, key, label)
      value = mapping[key]
      raise Error, "#{label}.#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?
    end

    def require_nested_strings(context, key, fields, label)
      value = context[key]
      require_mapping(value, "#{label}.#{key}")
      fields.each { |field| require_string(value, field, "#{label}.#{key}") }
    end

    def require_string_array(context, key, label)
      value = context[key]
      unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? } && value.uniq == value
        raise Error, "#{label}.#{key} must be an array of unique non-empty strings"
      end
    end

    def validate_model_aliases(value, label)
      require_mapping(value, "#{label}.model_aliases")
      raise Error, "#{label}.model_aliases must not be empty" if value.empty?

      value.each do |alias_name, pool_ids|
        unless alias_name.is_a?(String) && !alias_name.empty? && alias_name == alias_name.strip
          raise Error, "#{label}.model_aliases keys must be non-empty trimmed strings"
        end
        unless pool_ids.is_a?(Array) && !pool_ids.empty? &&
               pool_ids.all? { |pool_id| pool_id.is_a?(String) && !pool_id.empty? && pool_id == pool_id.strip } &&
               pool_ids.uniq == pool_ids
          raise Error, "#{label}.model_aliases.#{alias_name} must name one or more unique pools"
        end
      end
    end

    def validate_sha256(value, label)
      raise Error, "#{label} SHA-256 must be 64 lowercase hexadecimal characters" unless SHA256_PATTERN.match?(value)
    end

    def verify_directory(path, label, failures)
      failures << "#{label} is not a directory: #{path}" unless path && File.directory?(path)
    end

    def verify_file(path, label, failures)
      failures << "#{label} is not a file: #{path}" unless path && File.file?(path)
    end

    def verify_plan(context, failures)
      path = context.dig("afw", "plan_path")
      return unless File.file?(path)

      actual_sha256 = Digest::SHA256.file(path).hexdigest
      expected_sha256 = context.dig("plan", "sha256")
      failures << "plan SHA-256 mismatch: expected #{expected_sha256}, got #{actual_sha256}" unless actual_sha256 == expected_sha256

      plan_id = load_json_object(path, "AFW execution plan").fetch("plan_id")
      expected_plan_id = context.dig("plan", "plan_id")
      failures << "plan_id mismatch: expected #{expected_plan_id.inspect}, got #{plan_id.inspect}" unless plan_id == expected_plan_id
    rescue Error, KeyError => e
      failures << e.message
    end

    def verify_fleet_identity(context, failures)
      campaign_path = context.dig("rpof", "campaign_path")
      budget_path = context.dig("rpof", "budget_path")
      binding_path = context.dig("rpof", "binding_path")
      return unless [campaign_path, budget_path, binding_path].all? { |entry| File.file?(entry) }

      campaign = normalize_campaign(load_json_object(campaign_path, "RPOF campaign"))
      budget_document = load_json_object(budget_path, "RPOF campaign budget")
      registered_id = context.fetch("campaign_id")
      campaign_id = campaign.fetch("campaign_id")
      if campaign_id != registered_id
        failures << "campaign ID drift: expected #{registered_id.inspect}, got #{campaign_id.inspect}"
      end

      identity = normalize_identity(budget_document.fetch("campaign_identity"))
      if identity.fetch("campaign_id") != campaign_id
        failures << "budget is bound to campaign #{identity.fetch('campaign_id').inspect}, not #{campaign_id.inspect}"
      end

      campaign_sha256 = Digest::SHA256.hexdigest(JSON.generate(campaign))
      unless identity.fetch("campaign_sha256") == campaign_sha256
        failures << "campaign identity hash drift: expected #{identity.fetch('campaign_sha256')}, got #{campaign_sha256}"
      end

      identity_sha256 = Digest::SHA256.hexdigest(JSON.generate(identity))
      declared_identity_sha256 = digest!(
        budget_document.fetch("campaign_identity_sha256"),
        "campaign_identity_sha256"
      )
      unless declared_identity_sha256 == identity_sha256
        failures << "budget identity/hash mismatch: expected #{declared_identity_sha256}, got #{identity_sha256}"
      end

      budget = normalize_budget(budget_document, identity, campaign)
      binding_sha256 = Digest::SHA256.hexdigest(JSON.generate(budget))
      binding = load_json_object(binding_path, "RPOF durable campaign binding")
      unless binding["contract_version"] == "rpof-capacity-campaign-budget-state/v0.1"
        failures << "durable campaign binding has unsupported contract #{binding['contract_version'].inspect}"
      end
      unless binding["binding_sha256"] == binding_sha256
        failures << "budget binding hash mismatch: expected #{binding['binding_sha256'].inspect}, got #{binding_sha256}"
      end
      failures << "durable campaign binding declaration mismatch" unless binding["binding"] == budget
    rescue Error, KeyError, TypeError => e
      failures << "fleet identity invalid: #{e.message}"
    end

    def normalize_campaign(document)
      exact_keys!(document, CAMPAIGN_KEYS, "capacity campaign")
      unless document.fetch("contract_version") == "rpof-capacity-campaign/v0.1"
        raise Error, "capacity campaign contract is unsupported"
      end
      profiles = document.fetch("profiles")
      raise Error, "capacity campaign profiles must be a non-empty array" unless profiles.is_a?(Array) && !profiles.empty?

      normalized_profiles = profiles.map.with_index do |profile, index|
        exact_keys!(profile, PROFILE_KEYS, "profiles[#{index}]")
        minimum = positive_integer!(profile.fetch("min_workers"), "profiles[#{index}].min_workers")
        desired = positive_integer!(profile.fetch("desired_workers"), "profiles[#{index}].desired_workers")
        maximum = positive_integer!(profile.fetch("max_workers"), "profiles[#{index}].max_workers")
        unless minimum <= desired && desired <= maximum
          raise Error, "profiles[#{index}] worker counts are invalid"
        end
        unless profile.fetch("require_fully_gpu_resident") == true
          raise Error, "profiles[#{index}].require_fully_gpu_resident must be true"
        end
        {
          "profile_id" => nonempty_string!(profile.fetch("profile_id"), "profile_id"),
          "model" => nonempty_string!(profile.fetch("model"), "model"),
          "expected_digest" => digest!(profile.fetch("expected_digest"), "expected_digest"),
          "required_context_length" => positive_integer!(profile.fetch("required_context_length"), "required_context_length"),
          "require_fully_gpu_resident" => true,
          "min_workers" => minimum,
          "desired_workers" => desired,
          "max_workers" => maximum
        }
      end.sort_by { |profile| profile.fetch("profile_id") }

      {
        "contract_version" => "rpof-capacity-campaign/v0.1",
        "campaign_id" => nonempty_string!(document.fetch("campaign_id"), "campaign_id"),
        "max_workers" => positive_integer!(document.fetch("max_workers"), "max_workers"),
        "max_hourly_rate_usd" => positive_float!(document.fetch("max_hourly_rate_usd"), "max_hourly_rate_usd"),
        "profiles" => normalized_profiles
      }
    end

    def normalize_identity(identity)
      exact_keys!(identity, IDENTITY_KEYS, "campaign_identity")
      unless identity.fetch("contract_version") == "rpof-capacity-campaign-identity/v0.1"
        raise Error, "campaign identity contract is unsupported"
      end
      {
        "contract_version" => "rpof-capacity-campaign-identity/v0.1",
        "campaign_id" => nonempty_string!(identity.fetch("campaign_id"), "campaign identity campaign_id"),
        "campaign_sha256" => digest!(identity.fetch("campaign_sha256"), "campaign_sha256"),
        "hardware_qualification_sha256" => digest!(
          identity.fetch("hardware_qualification_sha256"),
          "hardware_qualification_sha256"
        )
      }
    end

    def normalize_budget(document, identity, campaign)
      exact_keys!(document, BUDGET_KEYS, "campaign budget")
      unless document.fetch("contract_version") == "rpof-capacity-campaign-budget/v0.1"
        raise Error, "campaign budget contract is unsupported"
      end
      max_workers = positive_integer!(document.fetch("max_workers"), "budget max_workers")
      max_rate = positive_float!(document.fetch("max_aggregate_hourly_rate_usd"), "budget max rate")
      raise Error, "budget max_workers does not match campaign" unless max_workers == campaign.fetch("max_workers")
      raise Error, "budget max rate does not match campaign" unless max_rate == campaign.fetch("max_hourly_rate_usd")

      {
        "contract_version" => "rpof-capacity-campaign-budget/v0.1",
        "campaign_identity" => identity,
        "campaign_identity_sha256" => digest!(document.fetch("campaign_identity_sha256"), "campaign_identity_sha256"),
        "budget_id" => nonempty_string!(document.fetch("budget_id"), "budget_id"),
        "max_cumulative_compute_usd" => positive_float!(document.fetch("max_cumulative_compute_usd"), "max cumulative compute"),
        "max_aggregate_hourly_rate_usd" => max_rate,
        "max_workers" => max_workers,
        "max_runtime_seconds" => positive_float!(document.fetch("max_runtime_seconds"), "max runtime"),
        "guardian_poll_seconds" => positive_float!(document.fetch("guardian_poll_seconds"), "guardian poll"),
        "orchestrator_heartbeat_timeout_seconds" => positive_float!(
          document.fetch("orchestrator_heartbeat_timeout_seconds"), "heartbeat timeout"
        ),
        "teardown_reserve_seconds" => positive_float!(document.fetch("teardown_reserve_seconds"), "teardown reserve")
      }
    end

    def load_json_object(path, label)
      value = JSON.parse(File.binread(path))
      raise Error, "#{label} must be a JSON object" unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => e
      raise Error, "#{label} is invalid JSON: #{e.message}"
    end

    def exact_keys!(value, required, label)
      raise Error, "#{label} must be a JSON object" unless value.is_a?(Hash)
      missing = required - value.keys
      unknown = value.keys - required
      raise Error, "#{label} missing field(s): #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{label} unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?
    end

    def digest!(value, label)
      raise Error, "#{label} must be a lowercase SHA-256" unless value.is_a?(String) && SHA256_PATTERN.match?(value)
      value
    end

    def nonempty_string!(value, label)
      raise Error, "#{label} must be a non-empty string" unless value.is_a?(String) && !value.empty? && value == value.strip
      value
    end

    def positive_integer!(value, label)
      raise Error, "#{label} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      value
    end

    def positive_float!(value, label)
      number = value.to_f if value.is_a?(Numeric)
      raise Error, "#{label} must be positive and finite" unless number&.positive? && number.finite?
      number
    end
  end
end
