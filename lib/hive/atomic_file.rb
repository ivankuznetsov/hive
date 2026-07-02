require "fileutils"
require "securerandom"

module Hive
  # The one way to write a small state file atomically: tempfile in the
  # same directory, then rename over the target. Either the target holds
  # the old content or the new content; a crash mid-write can never leave
  # it truncated or torn. The codebase grew several private copies of this
  # pattern (Markers, Events, Init, ServiceInstaller::Base, review
  # suppression, …) — new state files should use this helper instead of
  # adding another.
  module AtomicFile
    module_function

    # Write `content` to `path` atomically. `mode:` sets the permissions of
    # the newly created file (pass 0o600 for owner-private state). `fsync:`
    # flushes to disk before the rename — keep it on for state that must
    # survive a crash; a caller that measurably can't afford it may opt out.
    def write(path, content, mode: 0o644, fsync: true)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".#{File.basename(path)}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, mode) do |file|
        file.write(content)
        if fsync
          file.flush
          file.fsync
        end
      end
      File.rename(tmp, path)
      path
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
