# frozen_string_literal: true

BABYSITTER_DYNAMIC_LOADER_ENV = %w[
  LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG_OUTPUT
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH
].freeze
MAX_ESCAPED_ARGV_BYTES = 4 * 1024
MAX_SKIP_LOG_BYTES = 64 * 1024
SKIP_LOG_LOCK_TIMEOUT_SECONDS = 0.25
SKIP_LOG_LOCK_RETRY_SECONDS = 0.01
TRUNCATED_ARGV_SUFFIX = "...[truncated]"

def scrub_dynamic_loader_env!
  BABYSITTER_DYNAMIC_LOADER_ENV.each { |key| ENV.delete(key) }
end

def log_skip(command, argv)
  path = ENV.fetch("HIVE_BABYSITTER_DRY_RUN_LOG", ".babysitter-dry-run-skipped.log")
  message = "[dry-run] #{command} #{escaped_argv(argv)} skipped"
  append_skip_log(path, message)
rescue SystemCallError, IOError => e
  # The command is still skipped (stderr below preserves the human-visible signal), but the
  # persistent audit log just developed an invisible gap; surface the cause instead of
  # silently dropping the record. Catch IOError too (e.g. a closed stream on flush) so a
  # write/flush failure cannot escape, crash the stub, and drop the audit record. Name the
  # target path so the operator knows which log location (the override or the default) failed.
  warn "[dry-run] failed to write skip log #{path}: #{e.message}"
end

def append_skip_log(path, message)
  raise IOError, "File::NOFOLLOW unavailable" unless File.const_defined?(:NOFOLLOW)
  raise IOError, "File::NONBLOCK unavailable" unless File.const_defined?(:NONBLOCK)

  preopen_stat = begin
    stat = File.lstat(path)
    raise IOError, "dry-run skip log is not a regular file" unless stat.file?
    raise IOError, "dry-run skip log is not owned by uid #{Process.uid}" unless stat.uid == Process.uid
    raise IOError, "dry-run skip log link count is not 1" unless stat.nlink == 1
    raise IOError, "dry-run skip log permissions are not private" unless (stat.mode & 0o077).zero?

    stat
  rescue Errno::ENOENT
    nil
  end

  flags = File::WRONLY | File::APPEND | File::NOFOLLOW | File::NONBLOCK
  flags |= File::CREAT | File::EXCL unless preopen_stat

  File.open(path, flags, 0o600) do |file|
    stat = file.stat
    raise IOError, "dry-run skip log is not a regular file" unless stat.file?
    raise IOError, "dry-run skip log is not owned by uid #{Process.uid}" unless stat.uid == Process.uid
    raise IOError, "dry-run skip log link count is not 1" unless stat.nlink == 1
    raise IOError, "dry-run skip log permissions are not private" unless (stat.mode & 0o077).zero?
    if preopen_stat && (stat.dev != preopen_stat.dev || stat.ino != preopen_stat.ino)
      raise IOError, "dry-run skip log changed during open"
    end

    lock_skip_log(file)

    record = "#{message}\n"
    if file.stat.size + record.bytesize > MAX_SKIP_LOG_BYTES
      raise IOError, "dry-run skip log size limit reached"
    end

    file.write(record)
  end
rescue Errno::EEXIST, Errno::ENOENT => e
  raise IOError, "dry-run skip log changed during open: #{e.message}"
end

def lock_skip_log(file)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SKIP_LOG_LOCK_TIMEOUT_SECONDS
  until file.flock(File::LOCK_EX | File::LOCK_NB)
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise IOError, "timed out acquiring dry-run skip log lock" if remaining <= 0

    sleep [ SKIP_LOG_LOCK_RETRY_SECONDS, remaining ].min
  end
end

def escaped_argv(argv)
  escaped = argv.map { |arg| escape_control_chars(arg) }.join(" ")
  return escaped if escaped.bytesize <= MAX_ESCAPED_ARGV_BYTES

  prefix_bytes = MAX_ESCAPED_ARGV_BYTES - TRUNCATED_ARGV_SUFFIX.bytesize
  escaped.byteslice(0, prefix_bytes) + TRUNCATED_ARGV_SUFFIX
end

def escape_control_chars(arg)
  # Scan bytes, not characters: argv can carry non-UTF-8 bytes (git paths, agent-supplied
  # messages), and a UTF-8 `gsub` would raise ArgumentError on an invalid sequence - crashing
  # log_skip before its `rescue` and dropping the skip-log record. Binary-encode first so the
  # regex matches control bytes byte-by-byte; high bytes pass through unescaped, as before.
  arg.to_s.b.gsub(/[\x00-\x1f\x7f]/n) { |char| "\\x%02X" % char.ord }
end
