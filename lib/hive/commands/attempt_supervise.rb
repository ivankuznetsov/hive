require "hive/attempts/store"
require "hive/attempts/supervisor"

module Hive
  module Commands
    # Private argv adapter used only by DetachedLauncher. It intentionally is
    # not a Thor workflow verb or advertised in help.
    class AttemptSupervise
      def self.from_argv(argv)
        args = argv.dup
        attempt_id = args.shift
        options = {}
        until args.empty? || args.first == "--"
          key = args.shift
          value = args.shift
          raise Hive::UsageError, "missing value for #{key}" if value.nil?

          options[key] = value
        end
        args.shift if args.first == "--"
        raise Hive::UsageError, "attempt supervisor requires a worker command" if args.empty?

        new(
          attempt_id: attempt_id,
          store_root: options.fetch("--store-root"),
          worker_argv: args,
          heartbeat_sec: Float(options.fetch("--heartbeat-sec", 5)),
          stale_sec: Float(options.fetch("--stale-sec", 30)),
          first_heartbeat_timeout_sec: Float(options.fetch("--first-heartbeat-timeout-sec", 30)),
          timeout_sec: options["--timeout-sec"] && Float(options["--timeout-sec"]),
          kill_grace_sec: Float(options.fetch("--kill-grace-sec", 1))
        )
      rescue KeyError, ArgumentError => e
        raise Hive::UsageError, "invalid attempt supervisor invocation: #{e.message}"
      end

      def initialize(attempt_id:, store_root:, worker_argv:, heartbeat_sec:,
                     stale_sec:, first_heartbeat_timeout_sec:, timeout_sec:,
                     kill_grace_sec:)
        @attempt_id = attempt_id
        @store_root = store_root
        @worker_argv = worker_argv
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
          worker_argv: @worker_argv,
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
        value = ENV["HIVE_ATTEMPT_READY_FD"]
        return nil if value.to_s.empty?

        IO.for_fd(Integer(value), "w", autoclose: true)
      rescue ArgumentError, Errno::EBADF
        nil
      end
    end
  end
end
