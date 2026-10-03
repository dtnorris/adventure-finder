# frozen_string_literal: true

require_relative "adventure_finder_production_context"
require_relative "adventure_finder_worker_registry"

module AdventureFinderWorkspace
  class WorkerRegistryFrontDoor
    def initialize(registry:, bundle_executable: nil, runner: WorkerRegistryMerger::CommandRunner.new,
                   clock: nil, id_generator: nil)
      @registry = registry
      @bundle_executable = bundle_executable
      @runner = runner
      @clock = clock
      @id_generator = id_generator
    end

    def snapshot(batch_handle, state_root: nil)
      batch = @registry.resolve("batch", batch_handle)
      low_root = batch.dig("local_workers", "repository_root")
      raise Error, "batch #{batch_handle} has no registered LOW worker source" unless low_root
      fleet = resolve_fleet!(batch)
      rpof_root = fleet.dig("rpof", "repository_root")
      verify_source!("RPOF", rpof_root, "rpof")
      verify_source!("LOW", low_root, "low")
      bundle = find_executable!("bundle", @bundle_executable)
      sources = [
        source("rpof", rpof_root, "rpof", bundle),
        source("low", low_root, "low", bundle)
      ]
      root = state_root || File.join(batch.dig("wlo", "output_root"), "worker-registry-merge")
      WorkerRegistryMerger.new(
        state_root: root, sources:, runner: @runner, clock: @clock, id_generator: @id_generator
      ).snapshot
    end

    private

    def resolve_fleet!(batch)
      names = batch.fetch("associated_fleets")
      raise Error, "Batch has no registered worker-registry fleet" if names.empty?
      fleets = names.map { |name| @registry.resolve("fleet", name) }
      roots = fleets.map { |fleet| fleet.dig("rpof", "repository_root") }.uniq
      states = fleets.map { |fleet| fleet.dig("rpof", "state_root") }.uniq
      unless roots.length == 1 && states.length == 1
        raise Error, "Batch fleets do not share one registered RPOF worker-registry authority"
      end
      fleets.first
    end

    def source(name, root, executable, bundle)
      WorkerRegistryMerger::Source.new(
        name:, environment: { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
        argv: [bundle, "exec", File.join(root, "bin", executable), "workers", "--json"], chdir: root
      )
    end

    def verify_source!(label, root, executable)
      raise Error, "#{label} production root is not a directory: #{root}" unless File.directory?(root)
      path = File.join(root, "bin", executable)
      raise Error, "#{label} worker-registry executable is not executable: #{path}" unless File.executable?(path)
      gemfile = File.join(root, "Gemfile")
      raise Error, "#{label} Gemfile is not a file: #{gemfile}" unless File.file?(gemfile)
    end

    def find_executable!(name, configured)
      return File.expand_path(configured) if configured && File.executable?(configured)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        path = File.join(directory, name)
        return path if File.file?(path) && File.executable?(path)
      end
      raise Error, "required executable not found on PATH: #{name}"
    end
  end
end
