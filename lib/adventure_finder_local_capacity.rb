# frozen_string_literal: true

require "fileutils"
require "securerandom"
require_relative "adventure_finder_model_preflight"

module AdventureFinderWorkspace
  # Explicit operator action that materializes the frozen plan requirement and
  # hands it to LOW. Registry observation never calls this path.
  class LocalCapacity
    class ForegroundExecutor
      def call(environment, argv, chdir:)
        Kernel.exec(environment, *argv, chdir:)
      end
    end

    def initialize(registry:, executor: ForegroundExecutor.new, bundle_executable: nil,
                   capability_request_class: nil)
      @registry = registry
      @executor = executor
      @bundle_executable = bundle_executable
      @capability_request_class = capability_request_class
    end

    def bootstrap(batch_handle:, alias_name:)
      batch = @registry.resolve("batch", batch_handle)
      low_root = batch.dig("local_workers", "repository_root")
      raise Error, "batch #{batch_handle} has no registered LOW repository" unless low_root
      executable = File.join(low_root, "bin", "low")
      raise Error, "LOW bootstrap executable is not executable: #{executable}" unless File.executable?(executable)
      gemfile = File.join(low_root, "Gemfile")
      raise Error, "LOW Gemfile is not a file: #{gemfile}" unless File.file?(gemfile)

      artifacts = ModelPreflight.new(
        registry: @registry, capability_request_class: @capability_request_class
      ).resolve_artifacts(
        batch_handle: batch_handle.to_s, alias_name: alias_name.to_s
      )
      path = write_capability_request(
        batch, alias_name.to_s, artifacts.capability_request_bytes
      )
      argv = [find_executable!("bundle", @bundle_executable), "exec", executable, "bootstrap",
              "--capability-request", path, "--json"]
      @executor.call({ "BUNDLE_GEMFILE" => gemfile }, argv, chdir: low_root)
      0
    end

    private

    def write_capability_request(batch, alias_name, bytes)
      unless alias_name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)
        raise Error, "model alias is not safe for an evidence filename"
      end
      root = File.join(
        File.dirname(batch.dig("wlo", "output_root")), "local-capability-requests",
        batch.fetch("production_batch_id")
      )
      FileUtils.mkdir_p(root, mode: 0o700)
      path = File.join(root, "#{alias_name}.json")
      temporary = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
      path
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
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
