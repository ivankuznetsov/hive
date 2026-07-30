require "hive/lock"
require "hive/paths"
require "hive/pid_file"

module Hive
  module RefactorPatrol
    # Refuses a fresh-start reset while the profile daemon can still own a
    # released v2 writer. The operator command owns graceful stop/drain/restart;
    # this final PID/start-time check is the storage boundary's independent
    # fail-closed guard.
    class JobStoreWriterFence
      def initialize(
        pid_file: File.join(Hive::Paths.state_home, ".daemon.pid"),
        process: Process
      )
        @pid_file = pid_file
        @process = process
      end

      def assert_quiescent!
        return true unless File.exist?(@pid_file)

        payload = Hive::PidFile.read(@pid_file)
        pid = Integer(payload.fetch("pid"))
        return true unless Hive::PidFile.alive?(pid, process: @process)

        recorded = payload["process_start_time"]
        live = Hive::Lock.process_start_time(pid)
        unless recorded && live && recorded.to_s == live.to_s
          raise Hive::ConcurrentRunError.new(
            "cannot verify the live Hive daemon before JobStore reset",
            holder: { pid: pid },
            lock_path: @pid_file
          )
        end

        raise Hive::ConcurrentRunError.new(
          "stop the running Hive daemon (pid #{pid}) before JobStore reset",
          holder: {
            pid: pid,
            process_start_time: recorded
          },
          lock_path: @pid_file
        )
      rescue KeyError, ArgumentError, TypeError, Psych::Exception,
             SystemCallError, IOError => error
        raise Hive::ConcurrentRunError.new(
          "cannot verify the Hive daemon writer fence " \
          "(#{error.class}: #{error.message})",
          holder: {},
          lock_path: @pid_file
        )
      end
    end
  end
end
