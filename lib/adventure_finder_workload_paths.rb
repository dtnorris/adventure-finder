# frozen_string_literal: true

require "json"
require_relative "adventure_finder_state_paths"

module AdventureFinderWorkspace
  # Selects the public AFW producer and its store, or the retained combined route.
  class WorkloadPaths
    attr_reader :code, :data

    # Resolve selected directories. Public callers must explicitly select both
    # roots. Invalid or overlapping selections raise Error before owner writes.
    def initialize(code:, data:, explicit_code: true)
      @code = Pathname(code).expand_path unless code.to_s.strip.empty?
      raise Error, "select AF_AFW_ROOT explicitly" unless @code

      marker = @code.join("lib/af_workloads/public_distribution.rb")
      return unless data || marker.file?

      raise Error, "select AF_AFW_ROOT explicitly" unless explicit_code
      raise Error, "AF_AFW_ROOT must select the public af-workloads distribution: #{@code}" unless marker.file?

      @code = @code.realpath
      require @code.join("lib/af_workloads/roots").to_s
      @data = Pathname(AFWorkloads::Roots.data(data, code: @code))
      if @data.join("lib/af_workloads.rb").file?
        raise Error, "AF_AFW_DATA_ROOT must select workload storage separate from an AFW checkout"
      end
    rescue LoadError, SystemCallError => error
      raise Error, "AFW selection unavailable: #{error.message}"
    rescue StandardError => error
      raise unless defined?(AFWorkloads::Error) && error.is_a?(AFWorkloads::Error)

      raise Error, error.message
    end

    # Returns the selected store directory, including for historical bindings.
    def store
      data || code
    end

    # Returns CLI storage arguments for the public producer.
    def data_arguments
      data ? ["--data-root", data.to_s] : []
    end

    # Returns a JSON-compatible binding to the selected roots and producer bytes.
    def binding
      return unless data

      {"code_root" => code.to_s, "data_root" => StatePaths.binding(data),
       "generator" => AFWorkloads::Roots.generator(code.to_s, nil)}
    rescue AFWorkloads::Error => error
      raise Error, error.message
    end

    # Compare retained owner selectors before reading or replaying a workload.
    # A legacy preparation has no split binding. Mismatch raises Error.
    def verify_binding!(path)
      if path.exist? || path.symlink?
        unless data && !path.symlink? && path.file? && JSON.parse(File.binread(path)) == binding
          raise Error, "AFW code or data binding changed"
        end
      elsif data
        raise Error, "historical preparation has no split AFW binding"
      end
    rescue JSON::ParserError, SystemCallError => error
      raise Error, "invalid AFW binding: #{error.message}"
    end

    # Validate the scorer's configured workload output before creating preparation
    # state. Invalid selectors raise Error using the producer's path contract.
    def check_scorer!(repo, config)
      return unless data

      raise Error, "select AF_SCORER_ROOT and AF_SCORER_CONFIG explicitly" unless repo && config

      require code.join("lib/af_workloads/scorer_input_selection").to_s
      selection = AFWorkloads::ScorerInputSelection.load(config)
      AFWorkloads::Roots.owned(data.to_s, File.expand_path(selection.dig("paths", "output_root"), repo))
    rescue AFWorkloads::Error => error
      raise Error, error.message
    end
  end
end
