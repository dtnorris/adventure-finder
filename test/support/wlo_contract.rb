# frozen_string_literal: true

require "yaml"

# Match the front door's component-root contract, including explicit overrides.
# The real WLO contract is required; a missing checkout must not skip these tests.
WLO_ROOT = File.expand_path(
  ENV.fetch("WLO_REPOSITORY_ROOT") do
    component_root = ENV.fetch("AF_PROJECT_ROOT") do
      YAML.safe_load_file(File.expand_path("../../repos.yml", __dir__))
          .fetch("workspace_root_default")
    end
    File.join(component_root, "workload-orchestrator")
  end
) unless defined?(WLO_ROOT)

wlo_lib = File.join(WLO_ROOT, "lib")
contract = File.join(wlo_lib, "workload_orchestrator/ollama_capability_request.rb")
unless File.file?(contract)
  raise LoadError, "WLO capability contract not found: #{contract}; " \
                   "set WLO_REPOSITORY_ROOT or AF_PROJECT_ROOT to the intended checkout"
end

$LOAD_PATH.unshift(wlo_lib)
require contract
