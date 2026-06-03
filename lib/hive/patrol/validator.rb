require "open3"

module Hive
  module Patrol
    class Validator
      CommandResult = Struct.new(:name, :command, :exit_code, :stdout, :stderr, keyword_init: true) do
        def passed?
          exit_code.to_i.zero?
        end

        def to_h
          {
            "name" => name,
            "command" => command,
            "exit_code" => exit_code,
            "stdout" => tail(stdout),
            "stderr" => tail(stderr)
          }
        end

        # Keep the last 4000 chars for the audit trail. `str[-4000, 4000]`
        # returns nil when the string is shorter than 4000 chars (negative
        # start out of range), collapsing every short lint/test output to
        # "". A last-N slice preserves short strings intact.
        def tail(value)
          str = value.to_s
          str[-4000..] || str
        end
      end

      def initialize(commands)
        @commands = commands || {}
      end

      def validate(worktree_path)
        active = %w[format lint typecheck test].filter_map do |name|
          command = @commands[name]
          [ name, command ] if command.is_a?(String) && !command.strip.empty?
        end
        return { "passed" => false, "reason" => "no_validation_commands", "commands" => [] } if active.empty?

        results = active.map { |name, command| run_command(name, command, worktree_path) }
        {
          "passed" => results.all?(&:passed?),
          "commands" => results.map(&:to_h)
        }
      end

      private

      def run_command(name, command, worktree_path)
        out, err, status = Open3.capture3("bash", "-lc", command, chdir: worktree_path)
        CommandResult.new(name: name, command: command, exit_code: status.exitstatus, stdout: out, stderr: err)
      rescue SystemCallError => e
        CommandResult.new(name: name, command: command, exit_code: 127, stdout: "", stderr: e.message)
      end
    end
  end
end
