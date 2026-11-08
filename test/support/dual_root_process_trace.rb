# frozen_string_literal: true

require "digest"
require "json"

# Retains process-level executable/library provenance for the isolated journey.
# This observer adds no pipeline behavior and is never loaded by default suites.
trace_arguments = ARGV.dup
trace_directory = Dir.pwd
at_exit do
  if ENV["AF_DPS10_TRACE_ROOT"]
    code = ENV.fetch("AF_DATA_PIPELINE_ROOT", File.join(ENV.fetch("AF_PROJECT_ROOT"), "af-data-pipeline"))
    document = {
      "pid" => Process.pid, "parent_pid" => Process.ppid,
      "executable" => File.file?($PROGRAM_NAME) ? File.realpath($PROGRAM_NAME) : $PROGRAM_NAME,
      "executable_sha256" => File.file?($PROGRAM_NAME) ? Digest::SHA256.file($PROGRAM_NAME).hexdigest : nil,
      "cwd" => trace_directory, "argv" => trace_arguments,
      "code_root" => code, "data_root" => ENV["AF_DATA_PIPELINE_DATA_ROOT"],
      "libraries" => $LOADED_FEATURES.select { |path| path.include?("/af_data_pipeline") }.to_h do |path|
        [File.realpath(path), Digest::SHA256.file(path).hexdigest]
      end,
      "consumer_libraries" => $LOADED_FEATURES.select { |path| path.include?("/af_frontier") }.to_h do |path|
        [File.realpath(path), Digest::SHA256.file(path).hexdigest]
      end
    }
    File.binwrite(File.join(ENV.fetch("AF_DPS10_TRACE_ROOT"), "#{Process.pid}.json"), JSON.pretty_generate(document) + "\n")
  end
end
