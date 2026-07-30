require "fileutils"
require "hive"
require "hive/paths"

module Hive
  module Daemon
    # Stable profile-wide exclusion between daemon activation and maintenance
    # that must prove all daemon-owned writers are stopped. The lock inode is
    # never unlinked, so a waiter cannot race a replacement inode.
    class ActivationLock
      LOCK_NAME = ".daemon-activation.lock".freeze
      DEFAULT_TIMEOUT_SEC = 30

      attr_reader :path

      def initialize(
        hive_home: Hive::Paths.state_home,
        timeout_sec: DEFAULT_TIMEOUT_SEC,
        monotonic_clock: -> {
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        },
        sleeper: ->(seconds) { sleep(seconds) }
      )
        @hive_home = File.expand_path(hive_home)
        @path = File.join(@hive_home, LOCK_NAME)
        @timeout_sec = Float(timeout_sec)
        raise ArgumentError, "activation lock timeout must be non-negative" if
          @timeout_sec.negative?

        @monotonic_clock = monotonic_clock
        @sleeper = sleeper
        @handle = nil
      end

      def acquire!
        return self if @handle

        prepare_home!
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        handle = File.open(path, flags, 0o600)
        validate_binding!(handle)
        handle.chmod(0o600)
        validate_binding!(handle)
        deadline = @monotonic_clock.call + @timeout_sec
        until handle.flock(File::LOCK_EX | File::LOCK_NB)
          if @monotonic_clock.call >= deadline
            raise Hive::ConcurrentRunError.new(
              "daemon activation lock remained busy for " \
              "#{@timeout_sec}s",
              lock_path: path
            )
          end

          remaining = deadline - @monotonic_clock.call
          @sleeper.call([ 0.05, remaining ].min)
        end
        validate_binding!(handle)
        @handle = handle
        self
      rescue Hive::Error
        handle&.close
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError => error
        handle&.close
        raise Hive::ConfigError,
              "daemon activation lock is unavailable " \
              "(#{error.class}: #{error.message})"
      end

      def release!
        handle = @handle
        return false unless handle

        @handle = nil
        handle.flock(File::LOCK_UN)
        handle.close
        true
      rescue SystemCallError, IOError => error
        raise Hive::ConfigError,
              "daemon activation lock could not be released " \
              "(#{error.class}: #{error.message})"
      end

      def synchronize
        acquired_here = !@handle
        acquire!
        yield
      ensure
        release! if acquired_here && @handle
      end

      private

      def prepare_home!
        FileUtils.mkdir_p(@hive_home, mode: 0o700)
        stat = File.lstat(@hive_home)
        unless stat.directory? && !stat.symlink? &&
               stat.uid == Process.uid &&
               (stat.mode & 0o022).zero?
          raise Hive::ConfigError,
                "daemon activation lock directory is unsafe"
        end
      end

      def validate_binding!(handle)
        opened = handle.stat
        bound = File.lstat(path)
        valid = opened.file? && bound.file? &&
                !bound.symlink? &&
                opened.nlink == 1 && bound.nlink == 1 &&
                opened.uid == Process.uid &&
                bound.uid == Process.uid &&
                opened.dev == bound.dev &&
                opened.ino == bound.ino
        raise Hive::ConfigError,
              "daemon activation lock path is unsafe" unless valid

        true
      end
    end
  end
end
