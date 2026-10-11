# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.ruby_opts << "-r#{File.expand_path('test/support/subprocess_environment', __dir__)}"
  task.ruby_opts << "-r#{File.expand_path('test/support/simplecov_start', __dir__)}" if ENV["COVERAGE"] == "1"
end

desc "Run the functional suite with line and branch coverage and enforce the per-file baseline"
task "test:coverage" do
  FileUtils.rm_f(File.join(__dir__, "coverage", ".resultset.json"))
  sh({"COVERAGE" => "1"}, "rake", "test")
end

desc "Initialize the committed per-file coverage baseline from a passing measured suite"
task "test:coverage:baseline" do
  FileUtils.rm_f(File.join(__dir__, "coverage", ".resultset.json"))
  sh({"COVERAGE" => "1"}, "rake", "test")
  sh "bundle", "exec", "simplecov", "ratchet", "--init"
end

task default: "test:coverage"

desc "Run the offline cross-repository operator acceptance harness"
task "test:operator_acceptance" do
  sh File.expand_path("bin/af-operator-acceptance", __dir__)
end
