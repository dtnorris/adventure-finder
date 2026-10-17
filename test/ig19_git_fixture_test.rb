# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "support/ig19_git_fixture"

# Qualification never constructs history or invokes the fixture builder.
class Ig19GitFixtureTest < Minitest::Test
  # Give each negative control an independent disposable destination.
  def setup
    @temporary = Dir.mktmpdir("ig19 fixture qualification ")
  end

  # Remove only this test's extracted copies, including intentionally bad bytes.
  def teardown
    FileUtils.remove_entry(@temporary)
  end

  # Both exact histories qualify repeatedly without contaminating other copies.
  def test_native_history_and_manifest_bindings_are_repeatable_and_isolated
    %w[standing promotion].each do |name|
      first = Ig19GitFixture.load(name, File.join(@temporary, "#{name} first"))
      second = Ig19GitFixture.load(name, File.join(@temporary, "#{name} second"))
      assert_equal first.specification.fetch("files"), Ig19GitFixture.inventory(second.root)
      File.write(File.join(first.root, "application-output"), "isolated\n")
      refute File.exist?(File.join(second.root, "application-output"))
      assert first.verify!
      assert second.verify!
    end
  end

  # A changed descriptor or archive is rejected before destination creation.
  def test_changed_descriptor_and_archive_are_refused_before_extraction
    %w[json zip].each do |extension|
      directory = File.join(@temporary, extension)
      FileUtils.mkdir_p(directory)
      %w[standing.json standing.zip].each { |name| FileUtils.cp(File.join(Ig19GitFixture::DIRECTORY, name), directory) }
      File.open(File.join(directory, "standing.#{extension}"), "ab") { |file| file.write("changed") }
      destination = File.join(@temporary, "extracted #{extension}")
      error = assert_raises(RuntimeError) { Ig19GitFixture.load("standing", destination, directory:) }
      assert_includes error.message, "SHA-256 mismatch"
      refute File.exist?(destination)
    end
  end

  # Exercise the extraction checks directly, even with self-consistent hashes.
  # The public loader additionally requires the source-pinned descriptor.
  def test_escape_hooks_external_stores_and_links_are_rejected_before_any_write
    ["../escaped", "/absolute", ".git/objects/info/alternates", ".git/hooks/pre-commit",
     ".git/commondir", ".git/HEAD"].each_with_index do |name, index|
      archive = File.join(@temporary, "bad-#{index}.zip")
      bytes = "outside or executable dependency\n"
      Zip::OutputStream.open(archive) do |zip|
        entry = Zip::Entry.new("", name == "/absolute" ? "xabsolute" : name)
        if name == ".git/HEAD"
          entry.unix_perms = 0o120777
          entry.instance_variable_set(:@ftype, :symlink)
        end
        zip.put_next_entry(entry)
        zip.write(bytes)
      end
      File.binwrite(archive, File.binread(archive).gsub("xabsolute", "/absolute")) if name == "/absolute"
      files = {name => {"sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize}}
      destination = File.join(@temporary, "bad #{index}")
      assert_raises(RuntimeError) { Ig19GitFixture.extract!(archive, {"files" => files}, destination) }
      refute File.exist?(destination)
      refute File.exist?(File.join(@temporary, "escaped"))
    end
  end

  # Missing objects, dirty manifests/workbooks and stale HEAD cannot qualify.
  def test_missing_object_stale_head_manifest_and_workbook_are_refused
    %w[object head manifest workbook].each do |kind|
      fixture = Ig19GitFixture.load("standing", File.join(@temporary, kind))
      path = case kind
             when "object" then Dir[File.join(fixture.root, ".git/objects/*/*")].first
             when "head" then File.join(fixture.root, ".git/HEAD")
             when "manifest" then File.join(fixture.root, "PROJECT_STATE.yml")
             else File.join(fixture.root, fixture.specification.dig("manifest", "catalog_head", "filename"))
             end
      kind == "object" ? File.unlink(path) : File.binwrite(path, "changed\n")
      assert_raises(RuntimeError) { fixture.validate! }
    end
  end

  # Inventory comparisons cover added, deleted and changed metadata paths.
  def test_metadata_inventory_detects_added_deleted_and_changed_paths
    %w[added deleted changed].each do |kind|
      fixture = Ig19GitFixture.load("standing", File.join(@temporary, kind))
      path = File.join(fixture.root, ".git", kind == "added" ? "unexpected" : "index")
      kind == "deleted" ? File.unlink(path) : File.binwrite(path, "changed\n")
      assert_raises(RuntimeError) { fixture.verify! }
    end
  end
end
