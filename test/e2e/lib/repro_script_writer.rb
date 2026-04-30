require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "paths"
require_relative "sandbox_env"

module Hive
  module E2E
    class ReproScriptWriter
      def initialize(scenario_dir:, sandbox_dir:, run_home:, steps:, failed_index:)
        @scenario_dir = scenario_dir
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @steps = steps
        @failed_index = failed_index
      end

      def write
        FileUtils.mkdir_p(@scenario_dir)
        path = File.join(@scenario_dir, "repro.sh")
        File.write(path, script)
        File.chmod(0o755, path)
        path
      end

      private

      def script
        env = SandboxEnv.repro_env(@sandbox_dir, @run_home)
        # repro.sh lives at <repo>/test/e2e/runs/<id>/scenarios/<name>/repro.sh
        # — six parent dirs up reaches the repo root. realpath gives a clean
        # absolute path so a wrong depth surfaces visibly instead of silently
        # cd'ing into a stale parent.
        lines = [
          "#!/usr/bin/env bash",
          "set -euo pipefail",
          "cd \"$(realpath \"$(dirname \"$0\")/../../../../../..\")\""
        ]
        env.each { |key, value| lines << "export #{key}=#{Shellwords.escape(value.to_s)}" }
        lines << "echo 'Replaying setup and failed CLI-visible steps for #{@failed_index}'"
        @steps.first(@failed_index.to_i).each do |step|
          unless step.kind == "cli" || step.kind == "json_assert"
            lines << "# step skipped: kind=#{step.kind} (stateful)"
            next
          end

          args = Array(step.args["args"]).map(&:to_s)
          lines << Shellwords.join([ RbConfig.ruby, "-Ilib", "bin/hive", *args ])
        end
        lines.join("\n") + "\n"
      end
    end
  end
end
