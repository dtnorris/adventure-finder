# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "yaml"
require "zip"

# Versioned synthetic catalogs are constructed separately by the acceptance
# builder. Loading one copies existing bytes only, then checks native bindings.
module Ig19GitFixture
  DIRECTORY = File.expand_path("../fixtures/ig19", __dir__)
  # Source-pinned descriptors bind both archive bytes and exact reviewed recipes.
  DESCRIPTORS = {
    "standing" => "6eb15b6ccdc4b3f0a3229a7ed9111ec102872e1e997337ece9bd3c6933d10f24",
    "promotion" => "e4d52d397c71d9641d92197a1ebf5d0472b19b493ccbc4bbaac3c211b5f27c94"
  }.freeze
  ZIP_TIME = Time.utc(2026, 10, 8)
  GIT_ENV = {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
             "GIT_OPTIONAL_LOCKS" => "0", "LC_ALL" => "C"}.freeze

  # Return file identities, rejecting symlinks and special files; IO errors propagate.
  def self.inventory(root, directories: false)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each_with_object({}) do |path, files|
      next if %w[. ..].include?(File.basename(path))
      raise "IG-19 fixture contains a link or special file: #{path}" if File.symlink?(path) ||
        (!File.directory?(path) && !File.file?(path))
      files[path.delete_prefix(root + "/")] = {"type" => "directory"} if directories && File.directory?(path)
      files[path.delete_prefix(root + "/")] = {"sha256" => Digest::SHA256.file(path).hexdigest,
                                              "bytes" => File.size(path)} if File.file?(path)
    end
  end

  # Observe native Git bytes without inherited repository/config overrides; raise on failure.
  def self.git(root, *arguments)
    cleared = ENV.keys.grep(/\AGIT_/).to_h { |name| [name, nil] }
    stdout, stderr, status = Open3.capture3(cleared.merge(GIT_ENV), "/usr/bin/git", "-C", root, *arguments,
                                           binmode: true)
    raise "IG-19 native Git #{arguments.inspect}: #{stderr}" unless status.success?
    stdout
  end

  # Run a sealed-fixture workflow without Git's optional index-cache refreshes.
  # Returns the block's value and restores the caller's setting even on errors.
  # Required Git writes remain possible and are still rejected by Catalog#verify!.
  def self.with_read_only_git
    previous = ENV["GIT_OPTIONAL_LOCKS"]
    ENV["GIT_OPTIONAL_LOCKS"] = "0"
    yield
  ensure
    ENV["GIT_OPTIONAL_LOCKS"] = previous
  end

  # Use the owner's unchanged XLSX recipe with a fixed ZIP timestamp. Does not
  # change workbook XML, scores, public authority or application clocks.
  def self.with_fixed_zip_time(&block)
    require "minitest/mock"
    Zip::DOSTime.stub(:now, Zip::DOSTime.at(ZIP_TIME.to_i), &block)
  end

  # Extract an exact versioned fixture into an absent path, validate every byte
  # before returning it. Invalid inputs raise before callers
  # can begin application work. Construction is never performed here.
  def self.load(name, root, directory: DIRECTORY)
    descriptor = File.binread(File.join(directory, "#{name}.json"))
    raise "IG-19 fixture descriptor SHA-256 mismatch" unless
      Digest::SHA256.hexdigest(descriptor) == DESCRIPTORS.fetch(name)
    specification = JSON.parse(descriptor)
    archive = File.join(directory, "#{name}.zip")
    raise "IG-19 fixture archive SHA-256 mismatch" unless
      Digest::SHA256.file(archive).hexdigest == specification.fetch("archive_sha256")
    extract!(archive, specification, root)
    fixture = Catalog.new(root, specification)
    fixture.validate!
    fixture
  end

  # Validate all entry paths and bytes before creating an absent destination.
  # Invalid archives raise without applying application artifacts.
  def self.extract!(archive, specification, root)
    raise "IG-19 fixture destination exists" if File.exist?(root) || File.symlink?(root)
    files = specification.fetch("files")
    Zip::File.open(archive) do |zip|
      names = zip.entries.map(&:name)
      raise "IG-19 fixture entries differ" unless names.uniq.length == names.length && names.sort == files.keys.sort
      zip.each do |entry|
        allowed = entry.name.match?(%r{\A(?:PROJECT_STATE\.yml|5e_Adventure_Master_Catalog_[0-9.]+\.xlsx|\.git/(?:HEAD|config|index|refs/heads/main|objects/[0-9a-f]{2}/[0-9a-f]{38}))\z})
        raise "IG-19 unsafe fixture path: #{entry.name}" unless allowed && entry.file? && !entry.symlink?
        bytes = entry.get_input_stream.read
        raise "IG-19 fixture entry binding mismatch: #{entry.name}" unless
          files.fetch(entry.name) == {"sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize}
      end
      FileUtils.mkdir_p(root)
      zip.each do |entry|
        path = File.join(root, entry.name)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, entry.get_input_stream.read)
      end
    end
  end

  # One isolated application workspace backed by pre-existing Git bytes.
  # Complete endpoint inventories detect persisted changes, including added and
  # deleted files. They do not detect write-then-restore or contain descendants.
  class Catalog
    attr_reader :root, :specification

    # Retain the expected archive inventory; does not write anything.
    def initialize(root, specification)
      @root = File.expand_path(root)
      @specification = specification
      @metadata = Ig19GitFixture.inventory(File.join(@root, ".git"), directories: true)
    end

    # Verify exact archive bytes, native HEAD/tree/index/objects and manifest roles.
    # Raises on missing objects, mismatched workbooks or any unexpected metadata.
    def validate!
      raise "IG-19 extracted inventory mismatch" unless Ig19GitFixture.inventory(root) == specification.fetch("files")
      raise "IG-19 native HEAD mismatch" unless Ig19GitFixture.git(root, "rev-parse", "HEAD").strip == specification.fetch("head")
      Ig19GitFixture.git(root, "fsck", "--full", "--strict", "--no-reflogs")
      Ig19GitFixture.git(root, "diff", "--cached", "--no-ext-diff", "--exit-code", "HEAD", "--")
      manifest = YAML.safe_load_file(File.join(root, "PROJECT_STATE.yml"), aliases: false)
      raise "IG-19 manifest roles mismatch" unless manifest == specification.fetch("manifest")
      paths = ["PROJECT_STATE.yml"]
      %w[catalog_head matcher_authorized_baseline production_dependency_floor].each do |role|
        binding = manifest.fetch(role)
        filename = binding.fetch("filename")
        raise "IG-19 workbook manifest mismatch" unless specification.fetch("files").fetch(filename) == binding.slice("sha256", "bytes")
        Zip::File.open(File.join(root, filename)) { |zip| zip.each { |entry| entry.get_input_stream.read } }
        paths << filename
      end
      paths.uniq.each do |name|
        raise "IG-19 committed file mismatch: #{name}" unless
          Ig19GitFixture.git(root, "show", "HEAD:#{name}") == File.binread(File.join(root, name))
      end
      verify!
    end

    # Compare literal HEAD, all refs, index, config and object bytes, including additions.
    # Application workbooks and PROJECT_STATE.yml are intentionally outside this check.
    def verify!
      actual = Ig19GitFixture.inventory(File.join(root, ".git"), directories: true)
      raise "IG-19 forbidden Git metadata change" unless actual == @metadata
      true
    end

    # Finish a bounded proof with the same complete metadata comparison.
    # No flags, Git writes or platform-specific cleanup are needed.
    def close
      verify!
    end
  end
end
