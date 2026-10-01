# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "yaml"

module AdventureFinderWorkspace
  PRODUCTION_CONTEXT_SCHEMA_VERSION = "adventurefinder-production-context/v0.1"

  class ProductionContextRegistry
    HANDLE_TYPES = %w[batch fleet].freeze
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/

    attr_reader :path, :data

    def initialize(path)
      @path = Pathname(path).expand_path
      @data = YAML.safe_load(@path.read, permitted_classes: [], aliases: false)
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

      context = data.fetch("contexts").fetch(type).fetch(name) do
        raise Error, "unknown production context: #{type} #{name}"
      end
      {"handle" => "#{type} #{name}"}.merge(context)
    end

    def verify(type, name)
      context = resolve(type, name)
      failures = []

      case type.to_s.downcase
      when "batch"
        verify_directory(context.dig("afw", "repository_root"), "AFW production root", failures)
        verify_directory(context.dig("afw", "workload_root"), "AFW workload root", failures)
        verify_file(context.dig("afw", "plan_path"), "AFW execution plan", failures)
        verify_directory(context.dig("wlo", "repository_root"), "WLO production root", failures)
        verify_directory(context.dig("wlo", "output_root"), "WLO output root", failures)
        verify_plan(context, failures)
      when "fleet"
        verify_directory(context.dig("rpof", "repository_root"), "RPOF production root", failures)
        verify_file(context.dig("rpof", "campaign_path"), "RPOF campaign", failures)
        verify_file(context.dig("rpof", "budget_path"), "RPOF budget", failures)
        verify_directory(context.dig("rpof", "state_root"), "RPOF state root", failures)
        verify_campaign(context, failures)
      end

      failures
    end

    private

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

    def validate_batch(name, context)
      require_mapping(context, "batch #{name}")
      require_string(context, "production_batch_id", "batch #{name}")
      require_nested_strings(context, "afw", %w[repository_root workload_root plan_path], "batch #{name}")
      require_nested_strings(context, "wlo", %w[repository_root output_root], "batch #{name}")
      require_nested_strings(context, "plan", %w[plan_id sha256], "batch #{name}")
      require_nested_strings(context, "catalog_provenance", %w[filename sha256 authority], "batch #{name}")
      validate_sha256(context.dig("plan", "sha256"), "batch #{name} plan")
      validate_sha256(context.dig("catalog_provenance", "sha256"), "batch #{name} catalog")
      validate_absolute_paths(context, %w[afw.repository_root afw.workload_root afw.plan_path wlo.repository_root wlo.output_root], "batch #{name}")
      require_string_array(context, "associated_fleets", "batch #{name}")
    end

    def validate_fleet(name, context)
      require_mapping(context, "fleet #{name}")
      require_string(context, "campaign_id", "fleet #{name}")
      require_nested_strings(context, "rpof", %w[repository_root campaign_path budget_path state_root], "fleet #{name}")
      validate_absolute_paths(context, %w[rpof.repository_root rpof.campaign_path rpof.budget_path rpof.state_root], "fleet #{name}")
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

    def validate_sha256(value, label)
      raise Error, "#{label} SHA-256 must be 64 lowercase hexadecimal characters" unless SHA256_PATTERN.match?(value)
    end

    def validate_absolute_paths(context, fields, label)
      fields.each do |field|
        value = field.split(".").reduce(context) { |row, key| row.fetch(key) }
        raise Error, "#{label}.#{field} must be an absolute path" unless Pathname(value).absolute?
      end
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

      plan_id = JSON.parse(File.binread(path))["plan_id"]
      expected_plan_id = context.dig("plan", "plan_id")
      failures << "plan_id mismatch: expected #{expected_plan_id.inspect}, got #{plan_id.inspect}" unless plan_id == expected_plan_id
    rescue JSON::ParserError => e
      failures << "AFW execution plan is invalid JSON: #{e.message}"
    end

    def verify_campaign(context, failures)
      path = context.dig("rpof", "campaign_path")
      return unless File.file?(path)

      campaign_id = JSON.parse(File.binread(path))["campaign_id"]
      expected_campaign_id = context["campaign_id"]
      failures << "campaign_id mismatch: expected #{expected_campaign_id.inspect}, got #{campaign_id.inspect}" unless campaign_id == expected_campaign_id
    rescue JSON::ParserError => e
      failures << "RPOF campaign is invalid JSON: #{e.message}"
    end
  end
end
