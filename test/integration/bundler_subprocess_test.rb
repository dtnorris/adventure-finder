# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

# A small process-seam proof, not another full suite or acceptance runner.
class BundlerSubprocessTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_plain_and_bundled_rake_keep_coverage_and_isolate_fixture_children
    Dir.mktmpdir("bundler-subprocess-") do |root|
      FileUtils.mkdir_p(File.join(root, "test/support"))
      FileUtils.mkdir_p(File.join(root, "lib"))
      %w[Gemfile Gemfile.lock Rakefile .simplecov].each do |name|
        FileUtils.cp(File.join(ROOT, name), root)
      end
      %w[simplecov_start subprocess_environment].each do |name|
        FileUtils.cp(File.join(ROOT, "test/support/#{name}.rb"), File.join(root, "test/support"))
      end
      File.write(File.join(root, "lib/measured.rb"), "def measured(value)\n  value ? 1 : 2\nend\nmeasured(true)\nmeasured(false)\n")
      File.write(File.join(root, "guard.rb"), "ENV['FIXTURE_GUARD_LOADED'] = '1'\n")
      File.write(File.join(root, "test/fixture_test.rb"), <<~'RUBY')
        require "json"
        require "minitest/autorun"
        require "open3"
        require "rbconfig"
        require "measured"
        class FixtureTest < Minitest::Test
          def test_child_environment
            assert defined?(SimpleCov), "coverage prelude was lost"
            assert_equal "1", ENV.fetch("FIXTURE_GUARD_LOADED")
            %w[BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLER_SETUP BUNDLE_BIN_PATH].each do |key|
              assert_nil ENV[key], "fixture inherited #{key}"
            end
            stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-rjson", "-e",
              'puts JSON.generate([defined?(Bundler), ENV["FIXTURE_GUARD_LOADED"]])')
            assert status.success?, stderr
            assert_equal [nil, "1"], JSON.parse(stdout)
          end
        end
      RUBY
      baseline = Digest::SHA256.file(File.join(root, "Gemfile.lock")).hexdigest
      # Deliberately preserve Ruby options instead of discarding safety guards.
      caller_environment = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
      environment = ENV.keys.grep(/\A(?:BUNDLE|BUNDLER_)/).to_h { |key| [key, nil] }.merge(
        "RUBYOPT" => [caller_environment["RUBYOPT"], "-r#{File.join(root, 'guard.rb')}"].compact.join(" "),
        "RUBYLIB" => caller_environment["RUBYLIB"]
      )
      [["rake"], ["bundle", "exec", "rake"]].each do |command|
        stdout, stderr, status = Open3.capture3(environment, *command, chdir: root)
        assert status.success?, "#{command.join(' ')}: #{stdout}\n#{stderr}"
        assert_includes stdout, "1 runs, 8 assertions, 0 failures, 0 errors, 0 skips"
        assert_includes stdout + stderr, "Line coverage:"
        assert_includes stdout + stderr, "Branch coverage:"
        assert_equal baseline, Digest::SHA256.file(File.join(root, "Gemfile.lock")).hexdigest
      end
    end
  end
end
