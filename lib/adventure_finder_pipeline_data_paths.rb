# frozen_string_literal: true

require "pathname"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  # Locates AFDP-owned handoffs separately from executable code. AFDP retains
  # validation of its contents and all authority; this only bounds delegation.
  module PipelineDataPaths
    # Recognizes an explicitly configured cutover or a selected public checkout.
    # The independent expected store selector keeps admission active if code is replaced.
    def self.public_selection?(code_root, env: ENV)
      code = Pathname(code_root)
      env.key?("AF_PIPELINE_EXPECTED_DATA_ROOT") || code.basename.to_s == "af-pipeline" ||
        code.join("config/public_owners.tsv").file?
    end

    # Admits the selected code and storage before any owner call or write.
    # Returns the private root, or the legacy root for a historical selection.
    # Raises Error for missing selectors, a different store or an unpinned checkout.
    def self.admit!(code_root:, legacy_root:, env: ENV)
      return root(code_root:, legacy_root:, env:) unless public_selection?(code_root, env:)

      expected = env["AF_PIPELINE_EXPECTED_DATA_ROOT"]
      raise Error, "set AF_PIPELINE_EXPECTED_DATA_ROOT to the installed private pipeline store" unless expected
      raise Error, "set AF_DATA_PIPELINE_DATA_ROOT to the selected private pipeline store" unless env.key?("AF_DATA_PIPELINE_DATA_ROOT")

      data = root(code_root:, legacy_root:, env:)
      unless data == checked_directory(expected)
        raise Error, "AF_DATA_PIPELINE_DATA_ROOT differs from the installed private pipeline store"
      end

      repo = Manifest.new(File.expand_path("../repos.yml", __dir__)).repositories.find do |entry|
        entry.fetch("name") == "af-data-pipeline"
      end
      raise Error, "repos.yml must pin the public pipeline revision" unless repo && repo["revision"]

      CheckoutIdentity.verify!(checked_directory(code_root.to_s), repo)
      data
    end

    # Returns the selected private root (or the supplied legacy root when unset).
    # Inputs are code/legacy paths and environment; invalid or overlapping roots
    # raise Error before AdventureFinder creates a handoff directory.
    def self.root(code_root:, legacy_root:, env: ENV)
      return Pathname(legacy_root) unless env.key?("AF_DATA_PIPELINE_DATA_ROOT")

      code = checked_directory(env.fetch("AF_DATA_PIPELINE_ROOT", code_root.to_s))
      raise Error, "pipeline code selector conflicts with retained context" unless code == Pathname(code_root)
      unless code.join("bin/af-data").file? && code.join("bin/af-data").executable?
        raise Error, "pipeline code command is not executable: #{code}/bin/af-data"
      end
      data = checked_directory(env.fetch("AF_DATA_PIPELINE_DATA_ROOT"))
      if contained?(code, data) || contained?(data, code)
        raise Error, "private pipeline data root overlaps executable code"
      end
      unless data.writable? && (data.stat.mode & 0o222).positive?
        raise Error, "private pipeline data root is unwritable"
      end
      data
    end

    # Returns an existing absolute nonsymlink directory; invalid spelling,
    # missing directories or unsafe ancestors raise Error without writes.
    def self.checked_directory(value)
      path = Pathname(value)
      unless !value.strip.empty? && path.absolute? && !value.include?("\0") &&
          !value.split(File::SEPARATOR).any? { |part| %w[. ..].include?(part) }
        raise Error, "pipeline root must be an existing absolute directory without traversal"
      end
      check_ancestors!(path)
      raise Error, "pipeline root is not a directory: #{path}" unless path.directory?

      path
    end

    # Rejects a symlink in a destination or any ancestor. Takes a Pathname,
    # returns nil and raises Error for unsafe paths; creates no directories.
    def self.check_ancestors!(path)
      current = Pathname(path)
      loop do
        raise Error, "pipeline destination contains a symlink: #{current}" if current.symlink?
        break if current == current.parent

        current = current.parent
      end
      nil
    end

    # Returns whether path equals root or is a descendant; accepts Pathnames.
    def self.contained?(path, root)
      path == root || path.to_s.start_with?(root.to_s + File::SEPARATOR)
    end
  end
end
