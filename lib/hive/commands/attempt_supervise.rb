require "hive/attempts/store"
require "hive/attempts/supervisor"

module Hive
  module Commands
    # Private argv adapter used only by DetachedLauncher. It intentionally is
    # not a Thor workflow verb or advertised in help.
    class AttemptSupervise
      VALUE_OPTIONS = %w[
        --store-root --heartbeat-sec --stale-sec --first-heartbeat-timeout-sec
        --timeout-sec --kill-grace-sec
      ].freeze

      def self.from_argv(argv)
        args = argv.dup
        attempt_id = args.shift
        options = {}
        until args.empty?
          key = args.shift
          unless VALUE_OPTIONS.include?(key)
            raise Hive::InvalidTaskPath, "unknown attempt supervisor option #{key.inspect}"
          end
          value = args.shift
          raise Hive::InvalidTaskPath, "missing value for #{key}" if value.nil?

          options[key] = value
        end
        raise Hive::InvalidTaskPath, "attempt supervisor requires an attempt ID" if attempt_id.to_s.empty?

        new(
          attempt_id: attempt_id,
          store_root: options.fetch("--store-root"),
          heartbeat_sec: Float(options.fetch("--heartbeat-sec", 5)),
          stale_sec: Float(options.fetch("--stale-sec", 30)),
          first_heartbeat_timeout_sec: Float(options.fetch("--first-heartbeat-timeout-sec", 30)),
          timeout_sec: options["--timeout-sec"] && Float(options["--timeout-sec"]),
          kill_grace_sec: Float(options.fetch("--kill-grace-sec", 1))
        )
      rescue KeyError, ArgumentError => e
        raise Hive::InvalidTaskPath, "invalid attempt supervisor invocation: #{e.message}"
      end

      def initialize(attempt_id:, store_root:, heartbeat_sec:,
                     stale_sec:, first_heartbeat_timeout_sec:, timeout_sec:,
                     kill_grace_sec:)
        @attempt_id = attempt_id
        @store_root = store_root
        @heartbeat_sec = heartbeat_sec
        @stale_sec = stale_sec
        @first_heartbeat_timeout_sec = first_heartbeat_timeout_sec
        @timeout_sec = timeout_sec
        @kill_grace_sec = kill_grace_sec
      end

      def call
        ready_io = ready_io_from_env
        Hive::Attempts::Supervisor.new(
          store: Hive::Attempts::Store.new(root: @store_root),
          attempt_id: @attempt_id,
          claim_io: claim_io_from_env,
          ready_io: ready_io,
          heartbeat_sec: @heartbeat_sec,
          stale_sec: @stale_sec,
          first_heartbeat_timeout_sec: @first_heartbeat_timeout_sec,
          timeout_sec: @timeout_sec,
          kill_grace_sec: @kill_grace_sec,
          install_signal_handlers: true
        ).run
      end

      private

      def ready_io_from_env
        inherited_io("HIVE_ATTEMPT_READY_FD")
      end

      def claim_io_from_env
        inherited_io("HIVE_ATTEMPT_CLAIM_FD")
      end

      def inherited_io(key)
        value = ENV[key]
        return nil if value.to_s.empty?

        mode = key == "HIVE_ATTEMPT_CLAIM_FD" ? "r" : "w"
        IO.for_fd(Integer(value), mode, autoclose: true)
      rescue ArgumentError, Errno::EBADF
        nil
      end
    end
  end
end
