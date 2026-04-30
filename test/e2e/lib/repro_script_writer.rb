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
        lines = [
          "#!/usr/bin/env bash",
          "set -euo pipefail",
          "cd \"$(dirname \"$0\")/../../..\""
        ]
        env.each { |key, value| lines << "export #{key}=#{Shellwords.escape(value.to_s)}" }
        lines << "echo 'Replaying setup and failed CLI-visible steps for #{@failed_index}'"
        @steps.first(@failed_index.to_i).each do |step|
          next unless step.kind == "cli" || step.kind == "json_assert"

          args = Array(step.args["args"]).map(&:to_s)
          lines << Shellwords.join([ RbConfig.ruby, "-Ilib", "bin/hive", *args ])
        end
        lines.join("\n") + "\n"
      end
    end
  end
end
