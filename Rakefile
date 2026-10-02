# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

task default: :test

desc "Run the offline cross-repository operator acceptance harness"
task "test:operator_acceptance" do
  sh File.expand_path("bin/af-operator-acceptance", __dir__)
end
