# frozen_string_literal: true

# Separate process: only LOW production code is loaded. Runtime observations
# and explicit preload are fakes; parsing, CLI, evidence and publication are real.
require "json"
require "stringio"
require "tmpdir"
require "digest"
require "local_ollama_workers"

class OfflineClient
  attr_reader :preloads
  def initialize(requirement)
    @requirement = requirement
    @preloads = []
  end
  def endpoint = "http://127.0.0.1:11434"
  def version = "0.33.0"
  def installed_models
    [{ "model" => @requirement.fetch("model"), "digest" => @requirement.fetch("expected_digest") }]
  end
  def running_models
    [installed_models.first.merge(
      "context_length" => @requirement.fetch("required_context_length"),
      "fully_gpu_resident" => @requirement.fetch("require_fully_gpu_resident"),
      "runtime_size_bytes" => 30_000,
      "runtime_size_vram_bytes" => @requirement.fetch("require_fully_gpu_resident") ? 30_000 : 20_000
    )]
  end
  def preload!(model:, context_length:) = @preloads << [model, context_length]
end

results = ARGV.map do |path|
  Dir.mktmpdir("low-composition-") do |root|
    bytes = File.binread(path)
    request = LocalOllamaWorkers::OllamaCapabilityRequest.new(bytes)
    requirement = JSON.parse(bytes).fetch("ollama")
    client = OfflineClient.new(requirement)
    identity = { "worker_id" => "local-1", "generation_id" => "low-macos-#{'a' * 64}", "endpoint" => client.endpoint }
    observer = Struct.new(:identity) { def observe = identity }.new(identity)
    hardware = Struct.new(:gpu_id).new(requirement.fetch("required_gpu_id", "NVIDIA A40"))
    store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
    components = { observer:, client:, hardware_probe: hardware, evidence_store: store }
    out = StringIO.new
    err = StringIO.new
    code = LocalOllamaWorkers::CLI.run(
      ["bootstrap", "--capability-request", path, "--json"],
      env: { "LOW_STATE_ROOT" => root }, stdout: out, stderr: err, components:
    )
    raise err.string unless code.zero?
    evidence = JSON.parse(out.string)
    snapshot = Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
    raise "retained evidence not readable" unless store.load_for(identity) == evidence
    source = LocalOllamaWorkers::LocalWorkerSource.new(observer:, client:, evidence_store: store)
    workers = source.workers
    after = Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
    raise "read/publication rewrote retained evidence" unless snapshot == after
    raise "publication preloaded" unless client.preloads.length == 1
    raise "worker not published" unless workers.length == 1
    raise "artifact changed" unless File.binread(path) == bytes
    {
      "fingerprint" => request.fingerprint, "artifact_sha256" => Digest::SHA256.hexdigest(bytes),
      "generation_id" => workers.first.fetch("generation_id"), "evidence" => evidence,
      "read_only_publication" => true
    }
  end
end
raise "provider isolation violated" if $LOADED_FEATURES.any? { |p| p.match?(%r{/lib/(?:workload_orchestrator|runpod_ollama_fleet|adventure_finder)}) }
puts JSON.generate(results)
