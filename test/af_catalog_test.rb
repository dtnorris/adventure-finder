# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class AfCatalogTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  COMMAND = File.join(ROOT, "bin", "af-catalog")

  def test_converts_pdf_and_routes_reported_receipt
    Dir.mktmpdir("af-catalog-test") do |dir|
      converter_root = File.join(dir, "pdf-to-llm-md-converter")
      pipeline_root = File.join(dir, "af-data-pipeline")
      pdf = File.join(dir, "book.pdf")
      receipt = File.join(converter_root, "build", "book.conversion-receipt.json")
      routed = File.join(dir, "routed.txt")

      FileUtils.mkdir_p(File.join(converter_root, "bin"))
      FileUtils.mkdir_p(File.join(pipeline_root, "bin"))
      File.write(pdf, "%PDF-test")

      write_executable(
        File.join(converter_root, "bin", "convert-cached"),
        <<~RUBY
          #!/usr/bin/env ruby
          require "fileutils"
          output = ARGV.fetch(ARGV.index("--output-dir") + 1)
          receipt = #{receipt.inspect}
          FileUtils.mkdir_p(output)
          File.write(receipt, "{}")
          puts "Conversion receipt: \#{receipt}"
          exit 0
        RUBY
      )

      write_executable(
        File.join(pipeline_root, "bin", "af-ingest-next"),
        <<~RUBY
          #!/usr/bin/env ruby
          File.write(#{routed.inspect}, ARGV.fetch(0))
          puts "STATE: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
        RUBY
      )

      stdout, stderr, status = Open3.capture3(
        {
          "AF_PDF_CONVERTER_ROOT" => converter_root,
          "AF_DATA_PIPELINE_ROOT" => pipeline_root
        },
        COMMAND,
        pdf
      )

      assert status.success?, stderr
      assert_equal receipt, File.read(routed)
      assert_includes stdout, "STATE: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    end
  end

  def test_routes_reviewable_receipt_but_preserves_converter_nonzero_status
    Dir.mktmpdir("af-catalog-test") do |dir|
      converter_root = File.join(dir, "pdf-to-llm-md-converter")
      pipeline_root = File.join(dir, "af-data-pipeline")
      pdf = File.join(dir, "book.pdf")
      receipt = File.join(converter_root, "build", "book.conversion-receipt.json")

      FileUtils.mkdir_p(File.join(converter_root, "bin"))
      FileUtils.mkdir_p(File.join(pipeline_root, "bin"))
      File.write(pdf, "%PDF-test")

      write_executable(
        File.join(converter_root, "bin", "convert-cached"),
        <<~RUBY
          #!/usr/bin/env ruby
          require "fileutils"
          receipt = #{receipt.inspect}
          FileUtils.mkdir_p(File.dirname(receipt))
          File.write(receipt, "{}")
          puts "Conversion receipt: \#{receipt}"
          exit 2
        RUBY
      )

      write_executable(
        File.join(pipeline_root, "bin", "af-ingest-next"),
        <<~RUBY
          #!/usr/bin/env ruby
          puts "STATE: NEEDS_PAGE_REVIEW"
        RUBY
      )

      stdout, _stderr, status = Open3.capture3(
        {
          "AF_PDF_CONVERTER_ROOT" => converter_root,
          "AF_DATA_PIPELINE_ROOT" => pipeline_root
        },
        COMMAND,
        pdf
      )

      assert_equal 2, status.exitstatus
      assert_includes stdout, "STATE: NEEDS_PAGE_REVIEW"
    end
  end

  def test_streams_carriage_return_progress_before_converter_exits
    Dir.mktmpdir("af-catalog-test") do |dir|
      converter_root = File.join(dir, "pdf-to-llm-md-converter")
      pipeline_root = File.join(dir, "af-data-pipeline")
      pdf = File.join(dir, "book.pdf")
      receipt = File.join(converter_root, "build", "book.conversion-receipt.json")

      FileUtils.mkdir_p(File.join(converter_root, "bin"))
      FileUtils.mkdir_p(File.join(pipeline_root, "bin"))
      File.write(pdf, "%PDF-test")

      write_executable(
        File.join(converter_root, "bin", "convert-cached"),
        <<~RUBY
          #!/usr/bin/env ruby
          require "fileutils"
          $stdout.sync = true
          receipt = #{receipt.inspect}
          FileUtils.mkdir_p(File.dirname(receipt))
          print "\\r[=                   ] 1/2"
          sleep 0.5
          File.write(receipt, "{}")
          puts
          puts "Conversion receipt: \#{receipt}"
        RUBY
      )

      write_executable(
        File.join(pipeline_root, "bin", "af-ingest-next"),
        <<~RUBY
          #!/usr/bin/env ruby
          puts "STATE: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
        RUBY
      )

      env = {
        "AF_PDF_CONVERTER_ROOT" => converter_root,
        "AF_DATA_PIPELINE_ROOT" => pipeline_root
      }

      Open3.popen2e(env, COMMAND, pdf) do |_stdin, output, wait_thread|
        observed = +""

        until observed.include?("1/2")
          ready = IO.select([output], nil, nil, 1.0)
          refute_nil ready, "progress output was not streamed within 1 second"
          observed << output.readpartial(4096)
        end

        assert wait_thread.alive?, "converter exited before progress was observable"

        observed << output.read until output.eof?
        assert wait_thread.value.success?
        assert_includes observed, "Conversion receipt:"
      end
    end
  end

  private

  def write_executable(path, content)
    File.write(path, content)
    FileUtils.chmod("+x", path)
  end
end
