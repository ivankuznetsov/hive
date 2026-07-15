require "open3"
require "timeout"

module Hive
  module RefactorPatrol
    # Offline proof that the exact local executable can expose the reporting
    # command. The probe never consults GitHub and never mutates the checkout.
    class CapabilityProbe
      Result = Struct.new(:ok, :reason, :evidence, :executable, keyword_init: true) do
        def ok?
          ok == true
        end
      end

      def initialize(executable: nil, timeout_sec: 5, runner: nil)
        @executable = executable
        @timeout_sec = timeout_sec
        @runner = runner || method(:capture)
      end

      def call(project_root)
        root = File.realpath(project_root)
        executable = resolve_executable(root)
        return failure("capability_missing", "local Hive executable is missing or not executable") unless executable

        out, err, status = @runner.call(
          [ executable, "help", "refactor-patrol" ],
          chdir: root,
          timeout: @timeout_sec
        )
        unless status.success? && "#{out}\n#{err}".include?("refactor-patrol")
          return failure(
            "capability_unrunnable",
            "local Hive executable did not expose refactor-patrol",
            executable: executable,
            evidence: { "exit_status" => status.respond_to?(:exitstatus) ? status.exitstatus : nil,
                        "stderr" => err.to_s.byteslice(0, 500) }
          )
        end

        Result.new(ok: true, reason: nil, evidence: {}, executable: executable)
      rescue Timeout::Error
        failure("capability_unrunnable", "local Hive capability probe timed out",
                executable: safe_executable, evidence: { "error" => "timeout" })
      rescue Errno::ENOENT, Errno::EACCES, SystemCallError => e
        failure("capability_missing", "local Hive executable is unavailable",
                executable: safe_executable, evidence: { "error" => e.class.name })
      end

      private

      def resolve_executable(root)
        candidate = @executable || File.join(root, "bin", "hive")
        return nil unless File.file?(candidate) && File.executable?(candidate)

        File.realpath(candidate)
      end

      def safe_executable
        @executable && File.expand_path(@executable)
      end

      def capture(argv, chdir:, timeout:)
        Timeout.timeout(timeout) { Open3.capture3(*argv, chdir: chdir) }
      end

      def failure(reason, message, executable: nil, evidence: {})
        Result.new(
          ok: false,
          reason: reason,
          evidence: { "message" => message }.merge(evidence),
          executable: executable
        )
      end
    end
  end
end
