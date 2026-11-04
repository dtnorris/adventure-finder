# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class CatalogRootsTest < Minitest::Test
  def test_flat_and_component_layouts_route_from_detached_normal_and_production_front_doors
    Dir.mktmpdir("catalog roots") do |tmp|
      # Exercise symlinked parents on every platform (macOS /var -> /private/var).
      real_dir = File.join(tmp, "real")
      FileUtils.mkdir_p(real_dir)
      dir = File.join(tmp, "alias")
      File.symlink(real_dir, dir)
      [dir, File.join(dir, "adventure-finder-components")].each do |components|
        %w[adventure-finder adventure-finder-production].each do |name|
          front = File.join(dir, name)
          converter = File.join(components, "pdf-to-llm-md-converter")
          pipeline = File.join(components, "af-data-pipeline")
          [front, converter, pipeline].each { |path| FileUtils.mkdir_p(File.join(path, "bin")) }
          catalog = File.join(front, "bin/af-catalog")
          FileUtils.cp(File.expand_path("../bin/af-catalog", __dir__), catalog)
          FileUtils.cp_r(File.expand_path("../lib", __dir__), front)
          FileUtils.chmod(0o755, catalog)
          pdf = File.join(dir, "source.pdf")
          routed = File.join(dir, "routed.json")
          File.write(pdf, "%PDF-fixture")
          executable(File.join(converter, "bin/convert-cached"), <<~RUBY)
            require "fileutils"
            output = ARGV.fetch(ARGV.index("--output-dir") + 1)
            FileUtils.mkdir_p(output)
            receipt = File.join(output, "receipt.json")
            File.write(receipt, "{}")
            puts "Conversion receipt: \#{receipt}"
          RUBY
          executable(File.join(pipeline, "bin/af-ingest-next"), <<~RUBY)
            require "json"
            abort "converter override lost" unless ARGV.fetch(ARGV.index("--pdf-converter-root") + 1) == #{converter.inspect}
            File.write(#{routed.inspect}, JSON.generate(ENV.to_h.slice(
              "AF_PROJECT_ROOT", "AF_ADVENTURE_FINDER_ROOT", "AF_AFW_ROOT", "AF_SCORER_ROOT"
            )))
          RUBY
          afw = File.join(components, "af-workloads-production")
          scorer = File.join(components, "af-cli-scoring-utility-production")
          _stdout, stderr, status = Open3.capture3(
            {"AF_PROJECT_ROOT" => components, "AF_ADVENTURE_FINDER_ROOT" => nil,
             "AF_PDF_CONVERTER_ROOT" => nil, "AF_DATA_PIPELINE_ROOT" => nil,
             "AF_AFW_ROOT" => afw, "AF_SCORER_ROOT" => scorer}, catalog, pdf
          )
          assert status.success?, stderr
          assert_equal({"AF_PROJECT_ROOT" => components, "AF_ADVENTURE_FINDER_ROOT" => File.realpath(front),
                        "AF_AFW_ROOT" => afw, "AF_SCORER_ROOT" => scorer}, JSON.parse(File.read(routed)))
        end
      end
    end
  end

  private

  def executable(path, body)
    File.write(path, "#!/usr/bin/env ruby\n#{body}")
    FileUtils.chmod(0o755, path)
  end
end
