# frozen_string_literal: true

require_relative "adventure_finder_pipeline_data_paths"

module AdventureFinderWorkspace
  # Selects AF-owned coordination storage without changing code or owner locators.
  # Selection and destination checks are read-only; invalid roots raise Error.
  module StatePaths
    FAMILIES = %w[
      output/ingest-operations/v0.1 output/ingest-contexts/v0.1
      output/ingest-authorities/successor-version/v0.1
      output/staged-scoring-intents/v0.1 output/ingest-editorial-workspaces/v0.1
      output/staged-workload-preparations/v0.1 output/local-ingest-executions/v0.1
      output/ingest-boundary-continuations/v0.1 output/ingest-releases/v0.1
      operations/final-promotions output/local-capability-requests output/worker-sources
    ].freeze

    # Returns legacy storage when unset, otherwise an existing external directory.
    # Inputs select code, component and owner roots. Raises Error for invalid,
    # overlapping, unwritable or symlinked paths before any persistent write.
    def self.root(front_door_root:, project_root: nil, owner_roots: [], env: ENV)
      return Pathname(front_door_root).expand_path unless env.key?("AF_STATE_ROOT")

      selected = PipelineDataPaths.checked_directory(env.fetch("AF_STATE_ROOT"))
      unless selected.writable? && (selected.stat.mode & 0o222).positive?
        raise Error, "AF_STATE_ROOT is unwritable"
      end
      project = Pathname(project_root || env.fetch("AF_PROJECT_ROOT", Pathname(front_door_root).parent.to_s))
      roles = [front_door_root, File.expand_path("..", __dir__), *owner_roots]
      {
        "AF_DATA_PIPELINE_ROOT" => "af-data-pipeline",
        "AF_PDF_CONVERTER_ROOT" => "pdf-to-llm-md-converter",
        "AF_SOURCE_ROOT" => "md-for-llm-book-content",
        "AF_AFW_ROOT" => "af-workloads", "LOW_REPO_ROOT" => "local-ollama-workers",
        "AF_SCORER_ROOT" => "af-cli-scoring-utility",
        "WLO_REPO_ROOT" => "workload-orchestrator"
      }.each { |selector, name| roles << env.fetch(selector, project.join(name).to_s) }
      %w[AF_DATA_PIPELINE_DATA_ROOT AF_AFW_DATA_ROOT LOW_STATE_ROOT].each do |selector|
        roles << env.fetch(selector) if env.key?(selector)
      end
      roles << Pathname(Dir.home).join(".local/state/local-ollama-workers") unless env.key?("LOW_STATE_ROOT")
      roles.each do |value|
        role = Pathname(value).expand_path
        # Compare real existing ancestors as well as spelling: an owner selector
        # may use a supported symlink while the AF state selector may not.
        ancestor = role
        ancestor = ancestor.parent until ancestor.exist? || ancestor.symlink?
        role = ancestor.realpath.join(role.relative_path_from(ancestor))
        if PipelineDataPaths.contained?(selected, role) || PipelineDataPaths.contained?(role, selected)
          raise Error, "AF_STATE_ROOT overlaps a selected code or owner root: #{value}"
        end
      end
      FAMILIES.each do |family|
        destination = selected.join(family)
        check_destination!(destination, selected)
        raise Error, "AF state family is not a directory: #{destination}" if destination.exist? && !destination.directory?
      end
      selected
    rescue Error => error
      raise Error, "AF_STATE_ROOT: #{error.message}"
    rescue SystemCallError, ArgumentError, TypeError => error
      raise Error, "invalid AF_STATE_ROOT or selected role: #{error.class}"
    end

    # Checks an AF destination without creating files.
    # Takes a path and its namespace; returns nil or raises Error for escape,
    # symlinks, non-directory ancestors or unwritable existing directories.
    def self.check_destination!(path, namespace)
      raise Error, "AF state destination escapes namespace" unless PipelineDataPaths.contained?(path, namespace)

      current = path
      loop do
        raise Error, "AF state destination contains a symlink: #{current}" if current.symlink?
        if current.exist? && current != path && !current.directory?
          raise Error, "AF state destination ancestor is not a directory: #{current}"
        end
        if current.directory? && (!current.writable? || (current.stat.mode & 0o222).zero?)
          raise Error, "AF state destination is unwritable: #{current}"
        end
        break if current == namespace

        current = current.parent
      end
      nil
    end

    # Checks one operation's existing destinations before its first mutation.
    # Inputs are a validated namespace and UUID; unsafe descendants raise Error.
    def self.check_operation!(root, operation_id)
      FAMILIES.each do |family|
        path = root.join(family, operation_id)
        check_destination!(path, root)
        Dir.glob(path.join("**", "*"), File::FNM_DOTMATCH).each do |name|
          check_destination!(Pathname(name), root)
        end if path.directory?
      end
      check_destination!(root.join("output/ingest-contexts/v0.1", "#{operation_id}.json"), root)
      nil
    end

    # Captures the external directory identity for a new v0.3 resume context.
    # Takes a validated Pathname and returns JSON fields; stat errors propagate.
    def self.binding(root)
      {"root" => root.to_s, "device" => root.stat.dev, "inode" => root.stat.ino}
    end
  end
end
