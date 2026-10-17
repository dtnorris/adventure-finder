# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# Observe imports without dependencies loaded by unrelated tests in the suite.
module RuntimeDependencyIsolation
  # Require absolute library paths in a fresh Ruby and return its loaded features.
  # Child failures fail the test; malformed output raises JSON::ParserError.
  def loaded_features_in_subprocess(*paths)
    script = <<~'RUBY'
      require "json"
      ARGV.each { |path| require path }
      puts JSON.generate($LOADED_FEATURES)
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-e", script, *paths)
    assert status.success?, error
    JSON.parse(output)
  end
end
