# frozen_string_literal: true

require "json"
require "minitest/assertions"
require "open3"
require "rbconfig"

module Ig19cMatrixSupport
  REPOSITORY_ENV = {
    "adventure-finder" => nil,
    "af-data-pipeline" => "AF_DATA_PIPELINE_ROOT",
    "af-workloads" => "AF_AFW_SOURCE_ROOT",
    "workload-orchestrator" => "WLO_REPO_ROOT",
    "local-ollama-workers" => "LOW_REPO_ROOT",
    "af-cli-scoring-utility" => "AF_SCORER_ROOT"
  }.freeze
  REQUIRED_FIELDS = %i[
    id repository file tests input precondition identities gate allowed forbidden preserved next_action
  ].freeze

  def run_matrix!(label, matrix)
    validate_matrix!(matrix)
    results = grouped_tests(matrix).map do |(repository, file), tests|
      run_group(repository, file, tests)
    end
    failures = results.reject { |result| result.fetch(:status).success? }
    rows_by_group = matrix.group_by { |row| [row.fetch(:repository), row.fetch(:file)] }
    passed_rows = results.sum do |result|
      result.fetch(:status).success? ? rows_by_group.fetch(result.fetch(:group)).length : 0
    end
    evidence = {
      "matrix" => label,
      "rows" => matrix.length,
      "pass" => passed_rows,
      "fail" => matrix.length - passed_rows,
      "blocked" => 0,
      "groups" => results.map do |result|
        {
          "repository" => result.dig(:group, 0),
          "file" => result.dig(:group, 1),
          "tests" => result.fetch(:tests).length,
          "status" => result.fetch(:status).success? ? "PASS" : "FAIL"
        }
      end
    }
    puts "IG-19C #{label} evidence: #{JSON.generate(evidence)}"
    return if failures.empty?

    flunk failures.map { |result|
      "#{result.fetch(:group).join(':')} failed\n#{result.fetch(:output)}"
    }.join("\n")
  end

  private

  def validate_matrix!(matrix)
    assert_equal matrix.length, matrix.map { |row| row.fetch(:id) }.uniq.length
    matrix.each do |row|
      REQUIRED_FIELDS.each do |field|
        value = row.fetch(field)
        refute(value.respond_to?(:empty?) && value.empty?, "#{row.fetch(:id)} missing #{field}")
      end
      assert REPOSITORY_ENV.key?(row.fetch(:repository)), "unknown repository for #{row.fetch(:id)}"
      assert row.fetch(:tests).all? { |test| test.match?(/\Atest_[a-z0-9_]+\z/) },
             "unsafe test identity for #{row.fetch(:id)}"
    end
  end

  def grouped_tests(matrix)
    matrix.each_with_object({}) do |row, groups|
      key = [row.fetch(:repository), row.fetch(:file)]
      groups[key] ||= []
      groups[key].concat(row.fetch(:tests))
    end.transform_values(&:uniq)
  end

  def run_group(repository, file, tests)
    root = repository_root(repository)
    test_path = File.join(root, file)
    raise "IG-19C public owner test is missing: #{test_path}" unless File.file?(test_path)

    pattern = "/\\A(?:#{tests.join('|')})\\z/"
    command = [RbConfig.ruby, "-Ilib", "-Itest", file, "--name", pattern]
    environment = {}
    unless repository == "adventure-finder"
      environment["BUNDLE_GEMFILE"] = File.join(root, "Gemfile")
      command.unshift("exec")
      command.unshift("bundle")
    end
    output, status = Open3.capture2e(environment, *command, chdir: root)
    if status.success?
      assert_match(/#{tests.length} runs,/, output)
      assert_match(/0 failures, 0 errors/, output)
    end
    {group: [repository, file], tests:, output:, status:}
  end

  def repository_root(repository)
    return File.expand_path("..", __dir__) if repository == "adventure-finder"

    environment = REPOSITORY_ENV.fetch(repository)
    configured = ENV[environment]
    raise "IG-19C requires #{environment} for #{repository}" if configured.to_s.empty?

    File.expand_path(configured)
  end
end
