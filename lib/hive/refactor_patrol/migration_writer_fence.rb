require "hive/lock"
require "hive/paths"
require "hive/pid_file"

module Hive
  module RefactorPatrol
    # Prevents candidate conversion while another Hive daemon generation can
    # still write released JobStore v2 state. A daemon may migrate from inside
    # its own verified process; every other caller must first stop it.
    class MigrationWriterFence
      def initialize(
        pid_file: File.join(Hive::Paths.state_home, ".daemon.pid"),
        process: Process,
        allow_current_process: true,
        operation: "JobStore migration"
      )
        @pid_file = pid_file
        @process = process
        @allow_current_process = allow_current_process == true
        @operation = operation.to_s
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
            "cannot verify the live Hive daemon before #{@operation}",
            holder: { pid: pid }, lock_path: @pid_file
          )
        end
        return true if @allow_current_process && pid == @process.pid

        raise Hive::ConcurrentRunError.new(
          "stop the running Hive daemon (pid #{pid}) before #{@operation}",
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
          holder: {}, lock_path: @pid_file
        )
      end
    end
  end
end
