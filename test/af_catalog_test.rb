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
      acknowledgment = File.join(dir, "progress-acknowledged")
      routed = File.join(dir, "routed.txt")

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
          $stdout.flush
          acknowledgment = #{acknowledgment.inspect}
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
          until File.exist?(acknowledgment)
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              warn "converter timed out waiting for progress acknowledgment"
              exit 1
            end
            sleep 0.01
          end
          File.write(receipt, "{}")
          puts
          puts "Conversion receipt: \#{receipt}"
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

      env = {
        "AF_PDF_CONVERTER_ROOT" => converter_root,
        "AF_DATA_PIPELINE_ROOT" => pipeline_root
      }

      Open3.popen2e(env, COMMAND, pdf, pgroup: true) do |_stdin, output, wait_thread|
        observed = +""
        completed = false
        begin
          progress = "\r[=                   ] 1/2"
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
          until observed.include?(progress)
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            flunk "timed out waiting for streamed carriage-return progress" if remaining <= 0
            flunk "timed out waiting for streamed carriage-return progress" unless IO.select([output], nil, nil, remaining)
            begin
              observed << output.readpartial(4096)
            rescue EOFError
              flunk "catalog output ended before carriage-return progress: #{observed.inspect}"
            end
          end

          refute File.exist?(receipt), "converter created its receipt before progress was observable"
          refute File.exist?(routed), "router ran before converter acknowledgment"
          File.write(acknowledgment, "progress observed")

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          loop do
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            flunk "timed out waiting for catalog completion after acknowledgment" if remaining <= 0
            flunk "timed out waiting for catalog completion after acknowledgment" unless IO.select([output], nil, nil, remaining)
            begin
              observed << output.readpartial(4096)
            rescue EOFError
              break
            end
          end

          flunk "catalog did not exit after output EOF" unless wait_thread.join(1)
          assert wait_thread.value.success?, observed
          assert_includes observed, "Conversion receipt: #{receipt}"
          assert_equal receipt, File.read(routed)
          assert_includes observed, "STATE: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
          completed = true
        ensure
          unless completed
            begin
              Process.kill("TERM", -wait_thread.pid)
            rescue Errno::ESRCH
              # The test-owned process group has already exited.
            end
            wait_thread.join(0.5)
            begin
              Process.kill("KILL", -wait_thread.pid)
            rescue Errno::ESRCH
              # No test-owned processes remain.
            end
            wait_thread.join(1)
          end
        end
      end
    end
  end

  private

  def write_executable(path, content)
    File.write(path, content)
    FileUtils.chmod("+x", path)
  end
end
