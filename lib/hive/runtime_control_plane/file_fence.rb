require "fileutils"
require "hive"

module Hive
  module RuntimeControlPlane
    # Stable-inode bounded flock used by the installation-wide launch, writer,
    # and lifecycle-operation fences. Each owner opens its own descriptor so
    # shared launcher ownership is visible across processes. Descriptors are
    # close-on-exec and must never be handed to a launched child.
    class FileFence
      attr_reader :path, :mode

      def initialize(path:, timeout_sec:, monotonic_clock: nil, sleeper: nil,
                     label: "runtime fence")
        @path = File.expand_path(path)
        @timeout_sec = Float(timeout_sec)
        raise ArgumentError, "fence timeout must be non-negative" if @timeout_sec.negative?

        @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @label = label.to_s
        @handle = nil
        @mode = nil
      end

      def acquire_shared! = acquire_mode!(:shared)
      def acquire_exclusive! = acquire_mode!(:exclusive)
      def shared? = mode == :shared
      def exclusive? = mode == :exclusive
      def acquired? = !@handle.nil?

      def synchronize(mode = :exclusive)
        acquired_here = !acquired?
        acquire_mode!(mode) if acquired_here
        yield self
      ensure
        release! if acquired_here && acquired?
      end

      def release!
        handle = @handle
        return false unless handle

        @handle = nil
        @mode = nil
        handle.flock(File::LOCK_UN)
        handle.close
        true
      rescue SystemCallError, IOError => error
        raise Hive::ConfigError, "#{@label} could not be released (#{error.class}: #{error.message})"
      end

      private

      def acquire_mode!(requested_mode)
        return self if mode == requested_mode
        raise Hive::ConfigError, "runtime fence is already held in #{mode} mode" if acquired?

        prepare_parent!
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        handle = File.open(path, flags, 0o600)
        handle.close_on_exec = true
        validate_binding!(handle)
        handle.chmod(0o600)
        operation = requested_mode == :shared ? File::LOCK_SH : File::LOCK_EX
        deadline = @monotonic_clock.call + @timeout_sec
        until handle.flock(operation | File::LOCK_NB)
          if @monotonic_clock.call >= deadline
            raise Hive::ConcurrentRunError.new(
              "#{@label} remained busy for #{@timeout_sec}s", lock_path: path
            )
          end
          remaining = [ deadline - @monotonic_clock.call, 0.0 ].max
          @sleeper.call([ 0.05, remaining ].min)
        end
        validate_binding!(handle)
        @handle = handle
        @mode = requested_mode
        self
      rescue Hive::Error
        handle&.close
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError => error
        handle&.close
        raise Hive::ConfigError, "#{@label} is unavailable (#{error.class}: #{error.message})"
      end

      def prepare_parent!
        parent = File.dirname(path)
        FileUtils.mkdir_p(parent, mode: 0o700)
        status = File.lstat(parent)
        valid = status.directory? && !status.symlink? && status.uid == Process.uid &&
          (status.mode & 0o022).zero?
        raise Hive::ConfigError, "#{@label} directory is unsafe" unless valid
      end

      def validate_binding!(handle)
        opened = handle.stat
        bound = File.lstat(path)
        valid = opened.file? && bound.file? && !bound.symlink? && opened.nlink == 1 &&
          bound.nlink == 1 && opened.uid == Process.uid && bound.uid == Process.uid &&
          opened.dev == bound.dev && opened.ino == bound.ino
        raise Hive::ConfigError, "#{@label} path is unsafe" unless valid
      end
    end
  end
end
