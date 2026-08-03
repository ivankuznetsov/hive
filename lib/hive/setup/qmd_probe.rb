require "open3"
require "hive"
require "hive/secret_patterns"

module Hive
  module Setup
    module QmdProbe
      TIMEOUT_SEC = 10

      module_function

      def call(path, runner: method(:capture3_bounded))
        runner.call([ path, "--version" ])
      end

      def diagnostic(*parts, fallback: "")
        detail = parts.join("\n").lines.map(&:strip).find { |line| !line.empty? }
        text = Hive::SecretPatterns.redact(detail || fallback)
        text.gsub(/[\u0000-\u001f\u007f]/, " ").strip.slice(0, 1_000)
      end

      def capture3_bounded(argv, timeout_sec: TIMEOUT_SEC)
        Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stdout_reader = Thread.new { stdout.read }
          stderr_reader = Thread.new { stderr.read }
          unless wait_thread.join(timeout_sec)
            terminate_process_group(wait_thread.pid, wait_thread)
            raise Hive::Error,
                  "hive setup: qmd startup probe timed out after #{timeout_sec}s"
          end

          [ stdout_reader.value, stderr_reader.value, wait_thread.value ]
        ensure
          stdout_reader&.join(1)
          stderr_reader&.join(1)
        end
      end

      def terminate_process_group(pid, wait_thread)
        Process.kill("TERM", -pid)
        return if wait_thread.join(2)

        Process.kill("KILL", -pid)
        wait_thread.join(2)
      rescue Errno::ESRCH, Errno::ECHILD
      end
    end
  end
end
