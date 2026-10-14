# frozen_string_literal: true

require "pathname"
require "shellwords"

# Loaded in every Ruby child by the IG-19D validation entrypoint. Git reads may
# inspect owner checkouts; mutations must resolve inside the run's marked,
# temporary fixture root, with a local, contained .git directory.
module Ig19dDisposableGit
  READS = %w[rev-parse status diff show log ls-files ls-tree cat-file for-each-ref
             show-ref symbolic-ref describe merge-base rev-list check-ignore].freeze
  MUTATIONS = %w[init add commit commit-tree hash-object write-tree update-ref
                 read-tree checkout switch reset branch tag config remote apply].freeze

  def self.check!(arguments)
    args = arguments.dup
    environment = args.first.is_a?(Hash) ? args.shift : {}
    options = args.last.is_a?(Hash) ? args.pop : {}
    command = args.first
    return unless command

    words = command.is_a?(Array) ? [command.first, *args.drop(1)] : args
    if words.length == 1 && words.first.is_a?(String) && words.first.match?(/\bgit\b/)
      words = Shellwords.split(words.first)
      raise "IG-19D refuses shell Git expressions" if words.any? { |word| word.match?(/[|;&<>`]/) }
    end
    return unless File.basename(words.first.to_s) == "git"

    words = words.drop(1)
    cwd = File.expand_path(options.fetch(:chdir, Dir.pwd))
    while words.first == "-C"
      words.shift
      cwd = File.expand_path(words.shift || raise("missing Git directory"), cwd)
    end
    verb = words.shift
    raise "IG-19D refuses unsupported Git command #{verb.inspect}" unless
      (READS + MUTATIONS + ["clone"]).include?(verb)
    return if READS.include?(verb) && !(verb == "symbolic-ref" && words.length > 1)
    return if verb == "config" && words.any? { |word| %w[--get --get-all --list -l].include?(word) }
    return if verb == "remote" && (words.empty? || words == ["-v"] || words.first == "get-url")

    raise "IG-19D forbids Git path/config environment overrides" if
      (ENV.to_h.merge(environment.transform_keys(&:to_s))).any? do |key, value|
        value && key.match?(/\AGIT_(?:DIR|WORK_TREE|INDEX_FILE|COMMON_DIR|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|CONFIG)/)
      end
    root = File.realpath(ENV.fetch("IG19D_FIXTURE_ROOT"))
    marker = File.join(root, ".ig19d-disposable")
    raise "IG-19D fixture root is unverified" unless !File.symlink?(marker) &&
      File.binread(marker) == ENV.fetch("IG19D_FIXTURE_TOKEN")
    target = case verb
             when "clone"
               positions = words.reject { |word| word.start_with?("-") }
               raise "IG-19D clone must have explicit local source and destination" unless positions.length == 2 &&
                 File.directory?(File.expand_path(positions.first, cwd))
               File.expand_path(positions.last, cwd)
             when "init"
               File.expand_path(words.reject { |word| word.start_with?("-") }.last || cwd, cwd)
             else cwd
             end
    # Resolve every existing ancestor, including symlinks, before a target can
    # be created. A lexical /tmp prefix alone does not establish disposability.
    ancestor = target
    ancestor = File.dirname(ancestor) until File.exist?(ancestor)
    resolved = File.join(File.realpath(ancestor), target.delete_prefix(ancestor).sub(%r{\A/}, ""))
    raise "IG-19D refuses Git mutation outside disposable fixtures: #{target}" unless resolved.start_with?(root + "/")
    unless %w[init clone].include?(verb)
      repository = File.realpath(target)
      repository = File.dirname(repository) until File.exist?(File.join(repository, ".git")) || repository == root
      gitdir = File.join(repository, ".git")
      raise "IG-19D refuses unverified Git directory: #{gitdir}" unless
        File.directory?(gitdir) && !File.symlink?(gitdir) && File.realpath(gitdir).start_with?(root + "/")
      raise "IG-19D refuses fixture Git hooks" unless Dir.glob(File.join(gitdir, "hooks", "*")).all? do |path|
        path.end_with?(".sample") || !File.executable?(path)
      end
    end
    raise "IG-19D refuses global Git configuration" if words.any? { |word| %w[--global --system --file -f].include?(word) }
  end

  module ProcessMethods
    def spawn(*arguments)
      Ig19dDisposableGit.check!(arguments)
      super
    end
  end

  module KernelMethods
    def system(*arguments, **options)
      Ig19dDisposableGit.check!([*arguments, options])
      super
    end

    def exec(*arguments, **options)
      Ig19dDisposableGit.check!([*arguments, options])
      super
    end
  end
end

Process.singleton_class.prepend(Ig19dDisposableGit::ProcessMethods)
Kernel.prepend(Ig19dDisposableGit::KernelMethods)
