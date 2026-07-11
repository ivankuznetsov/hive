# frozen_string_literal: true

def log_skip(command, argv)
  path = ENV.fetch("HIVE_BABYSITTER_DRY_RUN_LOG", ".babysitter-dry-run-skipped.log")
  message = "[dry-run] #{command} #{escaped_argv(argv)} skipped"
  append_skip_log(path) { |file| file.puts(message) }
rescue SystemCallError, IOError => e
  # The command is still skipped (stderr below preserves the human-visible signal), but the
  # persistent audit log just developed an invisible gap; surface the cause instead of
  # silently dropping the record. Catch IOError too (e.g. a closed stream on flush) so a
  # write/flush failure cannot escape, crash the stub, and drop the audit record. Name the
  # target path so the operator knows which log location (the override or the default) failed.
  warn "[dry-run] failed to write skip log #{path}: #{e.message}"
end

def append_skip_log(path)
  raise IOError, "File::NOFOLLOW unavailable" unless File.const_defined?(:NOFOLLOW)
  raise IOError, "File::NONBLOCK unavailable" unless File.const_defined?(:NONBLOCK)

  loop do
    preopen_stat = begin
      stat = File.lstat(path)
      raise IOError, "dry-run skip log is not a regular file" unless stat.file?
      raise IOError, "dry-run skip log is not owned by uid #{Process.uid}" unless stat.uid == Process.uid
      raise IOError, "dry-run skip log link count is not 1" unless stat.nlink == 1

      stat
    rescue Errno::ENOENT
      nil
    end

    flags = File::WRONLY | File::APPEND | File::NOFOLLOW | File::NONBLOCK
    flags |= File::CREAT | File::EXCL unless preopen_stat
    opened = false

    begin
      File.open(path, flags, 0o600) do |file|
        opened = true
        stat = file.stat
        raise IOError, "dry-run skip log is not a regular file" unless stat.file?
        raise IOError, "dry-run skip log is not owned by uid #{Process.uid}" unless stat.uid == Process.uid
        raise IOError, "dry-run skip log link count is not 1" unless stat.nlink == 1
        if preopen_stat && (stat.dev != preopen_stat.dev || stat.ino != preopen_stat.ino)
          raise IOError, "dry-run skip log changed during open"
        end

        yield file
      end
      break
    rescue Errno::EEXIST
      raise if opened || preopen_stat
      # Another process won creation; retry from lstat and verify its file fully.
    end
  end
end

def escaped_argv(argv)
  argv.map { |arg| escape_control_chars(arg) }.join(" ")
end

def escape_control_chars(arg)
  # Scan bytes, not characters: argv can carry non-UTF-8 bytes (git paths, agent-supplied
  # messages), and a UTF-8 `gsub` would raise ArgumentError on an invalid sequence - crashing
  # log_skip before its `rescue` and dropping the skip-log record. Binary-encode first so the
  # regex matches control bytes byte-by-byte; high bytes pass through unescaped, as before.
  arg.to_s.b.gsub(/[\x00-\x1f\x7f]/n) { |char| "\\x%02X" % char.ord }
end
