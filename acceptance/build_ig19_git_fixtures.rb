# frozen_string_literal: true

require "tmpdir"
require_relative "../test/support/ig19_git_fixture"

# Explicit construction entrypoint, never required by a test or proof wrapper.
# Only a fresh mktmpdir child receives native Git mutations. Output must be a
# caller-selected directory; publication and source-checkout Git writes are absent.
abort "usage: AF_DATA_PIPELINE_ROOT=... ruby acceptance/build_ig19_git_fixtures.rb OUTPUT_DIRECTORY" unless ARGV.length == 1
pipeline = File.realpath(ENV.fetch("AF_DATA_PIPELINE_ROOT"))
$LOAD_PATH.unshift(File.join(pipeline, "lib"))
require "af_data_pipeline"
require File.join(pipeline, "test/support/standing_bulk_score_release_fixture")

output = File.expand_path(ARGV.fetch(0))
abort "output already exists" if File.exist?(output)
FileUtils.mkdir_p(output)
recipe_files = %w[test/support/standing_bulk_score_release_fixture.rb test/support/staged_scoring_fixture.rb
                  test/support/compatibility_amc_fixture.rb test/support/amc_fixture.rb]
provenance = {"pipeline_head" => Ig19GitFixture.git(pipeline, "rev-parse", "HEAD").strip,
              "recipe_sha256" => recipe_files.to_h { |name| [name, Digest::SHA256.file(File.join(pipeline, name)).hexdigest] },
              "builder_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
              "zip_timestamp" => Ig19GitFixture::ZIP_TIME.iso8601,
              "git" => Ig19GitFixture.git(pipeline, "--version").strip, "ruby" => RUBY_DESCRIPTION}
Dir.mktmpdir("ig19 construction ", File.dirname(output)) do |construction|
  %w[standing promotion].each do |name|
    catalog = File.join(construction, name)
    FileUtils.mkdir_p(catalog)
    manifest = nil
    Ig19GitFixture.with_fixed_zip_time do
      if name == "standing"
        producer = File.join(construction, "owner release")
        FileUtils.mkdir_p(producer)
        StandingBulkScoreReleaseFixture.new(root: producer)
        manifest = YAML.safe_load_file(File.join(producer, "PROJECT_STATE.yml"))
        FileUtils.cp(File.join(producer, "PROJECT_STATE.yml"), catalog)
        manifest.values.grep(Hash).map { |role| role.fetch("filename") }.uniq.each do |filename|
          FileUtils.cp(File.join(producer, filename), catalog)
        end
      else
        writer = Object.new.extend(CompatibilityAmcFixture)
        base = File.join(catalog, "5e_Adventure_Master_Catalog_1.0.xlsx")
        baseline = File.join(catalog, "5e_Adventure_Master_Catalog_0.5.xlsx")
        writer.write_compatible_amc(base, rows: [writer.compatible_row("ADV-0001", title: "Existing", scores: {"Seriousness" => 3})])
        FileUtils.cp(base, baseline)
        role = lambda do |path, version|
          {"version" => version, "filename" => File.basename(path), **AfDataPipeline::StandingBulkScorePolicy.file_binding(path)}
        end
        manifest = {"schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
                    "catalog_head" => role.call(base, "1.0"),
                    "matcher_authorized_baseline" => role.call(baseline, "0.5"),
                    "production_dependency_floor" => role.call(baseline, "0.5")}
        File.binwrite(File.join(catalog, "PROJECT_STATE.yml"), YAML.dump(manifest))
      end
    end
    environment = Ig19GitFixture::GIT_ENV.merge(
      "GIT_AUTHOR_NAME" => "Synthetic fixture", "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
      "GIT_COMMITTER_NAME" => "Synthetic fixture", "GIT_COMMITTER_EMAIL" => "fixture@example.invalid",
      "GIT_AUTHOR_DATE" => "2026-10-08T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-10-08T00:00:00Z")
    # This local lambda is the sole Git writer. Its cwd is a verified fresh child;
    # never accept arbitrary repository paths or inherited object/index overrides.
    mutate = lambda do |*arguments, input: ""|
      raise "construction path escaped" unless File.realpath(catalog).start_with?(File.realpath(construction) + "/")
      cleared = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
      stdout, stderr, status = Open3.capture3(cleared.merge(environment), "/usr/bin/git", "-C", catalog,
                                             *arguments, stdin_data: input, binmode: true)
      raise "fixture construction failed: #{arguments.inspect}: #{stderr}" unless status.success?
      stdout.strip
    end
    mutate.call("init", "--quiet", "--initial-branch=main", "--template=")
    remote = name == "standing" ? "fixture://ig19d-catalog" : "fixture://catalog"
    File.binwrite(File.join(catalog, ".git/config"), "[core]\n\trepositoryformatversion = 0\n\tfilemode = false\n\tbare = false\n\tlogallrefupdates = false\n[remote \"origin\"]\n\turl = #{remote}\n")
    entries = Dir.children(catalog).reject { |entry| entry == ".git" }.sort.map do |filename|
      object = mutate.call("hash-object", "-w", "--", filename)
      "100644 blob #{object}\t#{filename}\n"
    end.join
    tree = mutate.call("mktree", input: entries)
    head = mutate.call("commit-tree", tree, input: "IG-19 #{name} synthetic catalog\n")
    mutate.call("update-ref", "refs/heads/main", head)
    # Without -u the index contains portable zero stat entries, not construction
    # machine inode/mtime data. Proof observes it without optional refresh writes.
    mutate.call("read-tree", head)
    files = Ig19GitFixture.inventory(catalog)
    archive = File.join(output, "#{name}.zip")
    Zip::OutputStream.open(archive) do |zip|
      files.each_key do |filename|
        entry = Zip::Entry.new("", filename, time: Zip::DOSTime.at(Ig19GitFixture::ZIP_TIME.to_i))
        zip.put_next_entry(entry)
        zip.write(File.binread(File.join(catalog, filename)))
      end
    end
    specification = {"schema" => "ig19-sealed-catalog/v1", "head" => head, "manifest" => manifest,
                     "archive_sha256" => Digest::SHA256.file(archive).hexdigest,
                     "files" => files, "construction" => provenance}
    File.binwrite(File.join(output, "#{name}.json"), JSON.pretty_generate(specification) + "\n")
    extracted = Ig19GitFixture.load(name, File.join(construction, "verify #{name}"), directory: output)
    extracted.close
    puts JSON.generate(fixture: name, head:, archive_sha256: specification.fetch("archive_sha256"), files: files.length)
  end
end
