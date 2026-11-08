# frozen_string_literal: true

# Temporarily changes one regular, singly linked artifact inside a disposable
# fixture. The validator sees the original mode; cleanup restores exact bytes
# and mode even when the control raises. Unsafe paths raise before any write.
module FixtureArtifactMutation
  # Yields with changed bytes (or an absent file) at path, then restores it.
  # Returns the block result; unsafe paths, IO failures and block errors raise.
  def with_changed_artifact(path, changed)
    original_stat = File.lstat(path)
    raise "unsafe mutation artifact: #{path}" unless original_stat.file? && original_stat.nlink == 1 &&
      File.realpath(path).start_with?(File.realpath(root) + "/")

    original = File.binread(path)
    mode = original_stat.mode & 0o7777
    begin
      if changed.nil?
        File.unlink(path)
      else
        File.chmod(mode | 0o200, path)
        File.binwrite(path, changed)
        File.chmod(mode, path)
      end
      yield
    ensure
      if File.exist?(path) || File.symlink?(path)
        current = File.lstat(path)
        raise "unsafe restoration artifact: #{path}" unless current.file? && current.nlink == 1 &&
          File.realpath(path).start_with?(File.realpath(root) + "/")

        File.chmod(mode | 0o200, path)
        File.binwrite(path, original)
      else
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(original) }
      end
      File.chmod(mode, path)
      raise "artifact restoration differs: #{path}" unless File.binread(path) == original &&
        File.stat(path).mode & 0o7777 == mode
    end
  end
end
