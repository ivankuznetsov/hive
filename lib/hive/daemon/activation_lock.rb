require "hive/paths"
require "hive/runtime_control_plane/file_fence"

module Hive
  module Daemon
    # Stable profile-wide exclusion between daemon activation and maintenance
    # that must prove all daemon-owned writers are stopped. The lock inode is
    # never unlinked, so a waiter cannot race a replacement inode.
    class ActivationLock < Hive::RuntimeControlPlane::FileFence
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
        super(
          path: File.join(File.expand_path(hive_home), LOCK_NAME),
          timeout_sec: timeout_sec, monotonic_clock: monotonic_clock,
          sleeper: sleeper, label: "daemon activation lock"
        )
      end

      def acquire! = acquire_exclusive!
      def synchronize(&block) = super(:exclusive, &block)
    end
  end
end
