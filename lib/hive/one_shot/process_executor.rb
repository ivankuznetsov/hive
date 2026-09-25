require "json"
require "shellwords"
require "hive/errors"
require "hive/runtime_control_plane/process_guard"

module Hive
  module OneShot
    class ProcessExecutor
      Execution = Data.define(:exit_code, :envelope)

      def call(command, on_spawn: nil)
        pid = nil
        settled = false
        out_read, out_write = IO.pipe
        err_read, err_write = IO.pipe
        Hive::RuntimeControlPlane::ProcessGuard.before_fork!
        argv = Shellwords.split(command)
        hive_bin = ENV.fetch("HIVE_BIN", "hive")
        argv[0] = hive_bin if argv.first == "hive" || argv.first&.end_with?("/hive") ||
          argv.first == File.basename(hive_bin)
        pid = Process.spawn(
          *argv, in: File::NULL, out: out_write,
          err: err_write, pgroup: true
        )
        Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
        out_write.close
        err_write.close
        on_spawn&.call(pid)
        stdout_reader = Thread.new { out_read.read }
        stderr_reader = Thread.new { err_read.read }
        _pid, status = Process.wait2(pid)
        settled = true
        stdout = stdout_reader.value
        stderr = stderr_reader.value
        $stderr.write(stderr) unless stderr.empty?
        envelope = JSON.parse(stdout) unless stdout.strip.empty?
        Execution.new(exit_code: status.exitstatus || 1, envelope: envelope)
      rescue JSON::ParserError => error
        raise Hive::InternalError, "one-shot child returned invalid JSON: #{error.message}"
      rescue Exception
        terminate(pid) if pid && !settled
        raise
      ensure
        Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
        [ out_read, out_write, err_read, err_write ].compact.each do |io|
          io.close unless io.closed?
        end
      end

      private

      def terminate(pid)
        Process.kill("TERM", -pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
