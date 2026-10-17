# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "timeout"
require "tmpdir"
require "yaml"
require_relative "wlo_contract"
require File.join(WLO_ROOT, "lib/workload_orchestrator")
require_relative "../../lib/adventure_finder_operator_acceptance"
require_relative "../../lib/adventure_finder_batch"

# Disposable Batch 39 composition. Only publisher bytes and scorer payloads are
# fakes. Context resolution, action-check, foreground exec, loading, scheduling,
# retained attempts and public status all use the actual owner implementations.
class BatchDynamicFixture
  ROOT = File.expand_path("../..", __dir__)
  PLAN_RELATIVE = "workloads/production-batch-039-fresh-20260930/execution-plan.json"
  PRODUCTION_SHA = "0396dadb15bf0ca68238fd4f449ca99e58c3a4ee329dadc8a6e242f5da0ae5d1"
  attr_reader :root, :plan, :store, :output, :registry, :plan_path, :pools, :observations

  # Create a synthetic plan with exact frozen pools and legitimate paused state.
  # +jobs+ are synthetic descriptors; optional terminal counts use the existing
  # WLO fixture-builder API. Raises on missing/drifted production authority.
  def initialize(jobs:, complete: 1, failed: 1)
    @root = Dir.mktmpdir("fo25-batch039-")
    @output = File.join(root, "execution")
    @workdir = File.join(root, "afw")
    @plan_path = File.join(@workdir, "synthetic-plan.json")
    @registry = File.join(root, "contexts.yml")
    @observations, @children, @publications = [], {}, {}
    @children_mutex, @watchdogs = Mutex.new, {}
    @exitstatuses = {}
    @publication_start = Time.now.utc - 1000
    afw = ENV.fetch("AF_AFW_SOURCE_ROOT", File.join(File.dirname(WLO_ROOT), "af-workloads"))
    production = File.binread(File.join(afw, PLAN_RELATIVE))
    raise "production plan drift" unless Digest::SHA256.hexdigest(production) == PRODUCTION_SHA && production.bytesize == 209_279
    frozen = JSON.parse(production)
    raise "production accounting drift" unless frozen.fetch("jobs").length == 192
    @pools = frozen.fetch("pools")
    FileUtils.mkdir_p(@workdir)
    File.symlink(WLO_ROOT, File.join(root, "wlo"))
    %w[local remote].each { |name| create_publisher(name) }
    create_payload
    terminal = Array.new(complete + failed) do |index|
      {"job_id" => "retained-#{index}", "pool_id" => pools[index % pools.length].fetch("pool_id")}
    end
    descriptors = terminal + jobs
    document = {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => "fo25-synthetic-batch039",
      "failure_policy" => {"max_consecutive_failures" => 10, "max_total_failures" => 10},
      "pools" => pools,
      "jobs" => descriptors.map do |job|
        job.merge("argv" => [RbConfig.ruby, File.join(@workdir, "payload.rb"), job.fetch("job_id")])
      end
    }
    File.write(plan_path, JSON.generate(document))
    @plan = WorkloadOrchestrator::Plan.load(plan_path)
    @store = WorkloadOrchestrator::ExecutionStore.new(plan:, workdir: @workdir, output_dir: output)
    store.prepare!
    store.start!
    worker = WorkloadOrchestrator::DynamicWorkerRegistry.new(JSON.generate(snapshot("local", [worker("local", pools)])), now: Time.now.utc).entries.first
    plan.jobs.first(terminal.length).each_with_index do |job, index|
      attempt = store.record_dynamic_running!(job:, worker:, environment_keys: [])
      store.write_logs(job, "retained result #{job.id}\n", "")
      store.record_dynamic_terminal!(attempt:, status: index < complete ? "complete" : "failed", exit_status: index < complete ? 0 : 1)
    end
    store.pause!
    write_registry
  end

  # Release a fixture payload by ID. No execution/control evidence is edited.
  def release(id)
    File.write(File.join(@workdir, "#{id}.release"), "release\n")
  end

  # Atomically replace one fake publisher's document, retaining exact bytes for
  # attempt provenance assertions. Returns the document; invalid bytes may be
  # injected separately by tests at this declared publication boundary.
  def publish(name, workers, **options)
    document = snapshot(name, workers, **options)
    replace_publication(name, JSON.generate(document))
    document
  end

  # Construct a versioned publication with deterministic increasing past times.
  # Returns a wire hash; explicit expiry supports deterministic clock tests.
  def snapshot(name, workers, expires_at: Time.now.utc + 120)
    revision = (@publications.fetch(name, []).length + 1)
    {
      "contract_version" => "dynamic-worker-registry/v0.1", "registry_id" => "fo25-#{name}",
      "revision" => revision, "published_at" => (@publication_start + revision).iso8601,
      "expires_at" => expires_at.utc.iso8601, "workers" => workers
    }
  end

  # Inject publication bytes, including malformed replacements, without altering
  # WLO checkpoints. Returns the path; filesystem errors propagate.
  def replace_publication(name, bytes)
    path = File.join(root, name, "snapshot.json")
    File.write("#{path}.tmp", bytes)
    File.rename("#{path}.tmp", path)
    (@publications[name] ||= []) << bytes
    FileUtils.rm_f(File.join(root, name, "unavailable"))
    path
  end

  # Make one publisher command fail with its diagnostic; no provider is called.
  def unavailable(name)
    File.write(File.join(root, name, "unavailable"), "offline #{name} publisher unavailable\n")
  end

  # Build a canonical worker for selected frozen pools. Same logical worker ID
  # in distinct registries intentionally tests registry-qualified identity.
  def worker(name, selected_pools, generation: "generation-1")
    models = selected_pools.map do |pool|
      requirement = pool.dig("requirements", "ollama")
      {"context_length" => requirement.fetch("required_context_length"),
       "digest" => requirement.fetch("expected_digest"), "fully_gpu_resident" => true,
       "model" => requirement.fetch("model")}
    end.sort_by { |model| model.fetch("model") }
    labels = ["inference", "ollama", name == "local" ? "local" : "remote"].sort
    row = {
      "worker_id" => "shared-worker", "generation_id" => generation,
      "endpoint" => "http://127.0.0.1:#{name == 'local' ? 11441 : 11442}", "state" => "READY",
      "labels" => labels, "capabilities" => {"gpu_id" => "fo25-synthetic-gpu", "ollama" => {"models" => models}}
    }
    fingerprint!(row)
  end

  # Recompute the frozen public wire fingerprint after a deliberate corruption
  # of a capability; WLO still owns all validation and matching.
  def fingerprint!(row)
    row["capability_fingerprint"] = Digest::SHA256.hexdigest(JSON.generate(
      "gpu_id" => row.dig("capabilities", "gpu_id"), "labels" => row.fetch("labels"),
      "ollama_models" => row.dig("capabilities", "ollama", "models")
        .map { |model| model.slice("context_length", "digest", "fully_gpu_resident", "model") }
    ))
    row
  end

  # Invoke the unmodified public WLO CLI for cheap repeated observations. Return
  # [text, exit code]; owner errors propagate as nonzero results, never stubs.
  def public_wlo(*arguments)
    out, err = StringIO.new, StringIO.new
    code = WorkloadOrchestrator::CLI.new(arguments, out:, err:, root: WLO_ROOT).run
    [out.string + err.string, code]
  end

  # Generate YAML through real AF resolution/action-check for configuration-only
  # owner-contract tests. Capture only the final exec; load with real WLO.
  # Returns WorkerSourceSet; AF/WLO refusal propagates without omission.
  def generated_sources
    path = nil
    handoff = lambda do |_environment, argv, chdir:|
      path = argv.fetch(argv.index("--worker-sources-config") + 1)
    end
    AdventureFinderWorkspace::BatchFrontDoor.new(registry_path: registry,
      workspace_root: root, executor: handoff, out: StringIO.new).run("resume", "39")
    WorkloadOrchestrator::WorkerSourceConfiguration.load(path)
  end

  # Update only disposable registry authority, for explicit negative controls.
  # Receives the document; returns bytes written or propagates parse/IO errors.
  def configure
    document = YAML.safe_load_file(registry)
    yield document
    File.write(registry, YAML.dump(document))
  end

  # Record a real JSON public status/progress observation. Raises on CLI errors.
  def observe(phase)
    bytes, code = public_wlo("status", plan_path, "--output", output, "--json")
    raise bytes unless code.zero?
    JSON.parse(bytes).tap do |document|
      observations.reject! { |row| row.fetch("phase") == phase }
      observations << {"phase" => phase, "status" => document}
    end
  end

  # Poll an explicit public predicate, bounded independently of WLO lifetime.
  # Returns its successful value or raises Timeout::Error with retained logs.
  def await(phase, seconds: 8)
    Timeout.timeout(seconds) do
      loop do
        value = yield observe(phase)
        return value if value
        sleep 0.02
      end
    end
  rescue Timeout::Error
    raise Timeout::Error, "#{phase}: #{diagnostics}"
  end

  # Start the actual AF binary with hostile inherited lockfile authority. The
  # child execs real WLO; separate files capture binary stdout and stderr.
  # Returns its owned PID; no launch/loader/scheduler seam is replaced.
  def launch(action = "resume")
    guard = File.join(ROOT, "test/support/offline_network_guard.rb")
    environment = AdventureFinderWorkspace::OperatorAcceptance::CREDENTIAL_NAMES.to_h { |name| [name, nil] }
    environment.merge!("BUNDLE_GEMFILE" => nil, "BUNDLE_LOCKFILE" => File.join(root, "hostile.lock"),
      "RUBYOPT" => [ENV["RUBYOPT"], "-r#{guard}"].compact.join(" "))
    argv = [RbConfig.ruby, File.join(ROOT, "bin/af-batch"), action, "39", "--root", root, "--registry", registry]
    pid = Process.spawn(environment, *argv, chdir: @workdir,
      out: File.join(root, "owner.stdout"), err: File.join(root, "owner.stderr"))
    @children_mutex.synchronize { @children[pid] = true }
    @watchdogs[pid] = Thread.new do
      sleep 30
      signal_owned(pid, "TERM")
      sleep 3
      signal_owned(pid, "KILL")
    end
    pid
  end

  # Reap only a child started here. Returns Process::Status or raises on timeout.
  def wait(pid, seconds: 10)
    Timeout.timeout(seconds) do
      Thread.handle_interrupt(Timeout::Error => :on_blocking) do
        @children_mutex.synchronize do
          Process.waitpid2(pid).last.tap { @children.delete(pid) }
        end
      end
    end.tap do |status|
      @watchdogs.delete(pid)&.kill
      @exitstatuses[pid] = {"exitstatus" => status.exitstatus, "termsig" => status.termsig}
    end
  end

  # Preserve complete attempt/result bytes for the supplied original job IDs.
  # Returns a relative-path/digest map; never normalizes retained evidence.
  def retained_evidence(ids)
    ids.flat_map { |id| Dir.glob(File.join(output, "runs", id, "**", "*")) }
       .select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix(output), Digest::SHA256.file(path).hexdigest] }
  end

  # Return immutable source bytes indexed by SHA for exact attempt comparison.
  def publication_bytes
    @publications.values.flatten.to_h { |bytes| [Digest::SHA256.hexdigest(bytes), bytes] }
  end

  # Report original logs/status without modifying failed fixtures.
  def diagnostics
    %w[owner.stdout owner.stderr].to_h do |name|
      path = File.join(root, name)
      bytes = File.file?(path) ? File.binread(path) : "not launched"
      [name, {"path" => path, "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes), "tail" => bytes.byteslice(-2000, 2000) || bytes}]
    end.inspect
  end

  # Teardown only positively owned unreaped children. WLO's TERM handler cancels
  # its own publisher/payload groups; payloads also have an independent deadline.
  # Returns nil; an unresponsive owner is killed by PID and always reaped.
  # +preserve+ retains failed fixtures. FO25_EVIDENCE_ROOT retains proof artifacts
  # when the operator requests an auditable validation transcript.
  def close(preserve: false)
    @children.keys.each do |pid|
      next unless @children[pid]
      signal_owned(pid, "TERM")
      begin
        wait(pid, seconds: 3)
      rescue Timeout::Error
        signal_owned(pid, "KILL")
        wait(pid, seconds: 3)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      @children.delete(pid)
      @watchdogs.delete(pid)&.kill
    end
    File.write(File.join(root, "public-observations.json"), JSON.pretty_generate(observations))
    File.write(File.join(root, "child-status.json"), JSON.pretty_generate(@exitstatuses))
    if ENV["FO25_EVIDENCE_ROOT"]
      destination = File.expand_path(ENV.fetch("FO25_EVIDENCE_ROOT"))
      FileUtils.mkdir_p(destination)
      FileUtils.cp_r(root, File.join(destination, File.basename(root)))
    end
    FileUtils.remove_entry(root) unless preserve
    nil
  end

  private

  # Serialize signals with reaping so a PID can never be signalled after this
  # fixture reaps it. Unreaped children cannot have their PIDs reused by the OS.
  # Returns the signal count or nil for an already exited child.
  def signal_owned(pid, signal)
    @children_mutex.synchronize { Process.kill(signal, pid) if @children.key?(pid) }
  rescue Errno::ESRCH
    nil
  end

  # Create one fake observational publisher, with actual component Bundler and
  # argv/environment assertions. Any bootstrap/provider action fails explicitly.
  def create_publisher(name)
    directory = File.join(root, name)
    FileUtils.mkdir_p(File.join(directory, "bin"))
    File.write(File.join(directory, "Gemfile"), "")
    executable = File.join(directory, "bin", name == "local" ? "low" : "rpof")
    File.write(executable, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      root = File.expand_path("..", __dir__)
      abort "forbidden capacity operation" unless ARGV == %w[workers --json]
      abort "foreign lockfile" if ENV["BUNDLE_LOCKFILE"] && ENV["BUNDLE_LOCKFILE"] != File.join(root, "Gemfile.lock")
      abort "foreign bundle" unless ENV.fetch("BUNDLE_GEMFILE") == File.join(root, "Gemfile")
      if File.basename($0) == "rpof"
        abort "remote authority drift" unless ENV.fetch("RPOF_STATE_ROOT") == File.join(root, "state") && ENV.fetch("RPOF_STATE_REPO_ROOT") == root
      end
      File.open(File.join(root, "calls.jsonl"), "a") { |file| file.puts(JSON.generate(ARGV)) }
      abort File.read(File.join(root, "unavailable")) if File.file?(File.join(root, "unavailable"))
      STDOUT.binmode
      STDOUT.write(File.binread(File.join(root, "snapshot.json")))
    RUBY
    File.chmod(0o755, executable)
  end

  # Write the sole executable scorer substitute. Each payload records its
  # endpoint, waits for a fixture release, and exits within eight seconds.
  def create_payload
    File.write(File.join(@workdir, "payload.rb"), <<~'RUBY')
      require "json"
      require "timeout"
      id = ARGV.fetch(0)
      File.write("#{id}.started", JSON.generate("pid" => Process.pid, "endpoint" => ENV.fetch("WLO_WORKER_ENDPOINT")))
      Timeout.timeout(8) { sleep 0.01 until File.file?("#{id}.release") }
      STDOUT.binmode
      STDOUT.write("synthetic result #{id}\x00\xFF\n".b)
    RUBY
  end

  # Register only synthetic plan authority beneath this fixture root. Original
  # Batch 39 plan hash/configuration and component source trees stay untouched.
  def write_registry
    document = YAML.safe_load_file(File.join(ROOT, "config/production_contexts.yml"))
    batch = document.dig("contexts", "batch", "39")
    batch["production_batch_id"] = plan.id
    batch["afw"] = {"repository_root" => "afw", "workload_root" => "afw", "plan_path" => "afw/synthetic-plan.json"}
    batch["wlo"] = {"repository_root" => "wlo", "output_root" => "execution"}
    batch["local_workers"] = {"repository_root" => "local"}
    batch["plan"] = {"plan_id" => plan.id, "sha256" => plan.sha256}
    rpof = document.dig("contexts", "fleet", "A", "rpof")
    rpof.replace({"repository_root" => "remote", "campaign_path" => "remote/campaign.json",
      "budget_path" => "remote/budget.json", "state_root" => "remote/state", "binding_path" => "remote/binding.json"})
    File.write(registry, YAML.dump(document))
  end
end
