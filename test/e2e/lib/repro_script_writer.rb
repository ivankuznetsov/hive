require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "paths"
require_relative "sandbox_env"

module Hive
  module E2E
    class ReproScriptWriter
      # Step kinds whose effect is pure file/state I/O — safe to replay
      # offline. tui_keys / tui_expect / wait_subprocess / editor_action
      # all need a live tmux pane the bare bash repro can't bootstrap, so
      # they're skipped with a comment instead of executed.
      REPLAYABLE_KINDS = %w[
        cli json_assert seed_state write_file register_project
        ruby_block state_assert log_assert
      ].freeze

      LIVE_TMUX_KINDS = %w[tui_keys tui_expect wait_subprocess editor_action].freeze

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
        # Setup-step replay (seed_state / write_file / register_project)
        # references the sandbox by an explicit env var so the heredoc bodies
        # stay readable — neither SandboxEnv.repro_env nor the shell otherwise
        # carries the path through.
        lines << "export HIVE_SANDBOX_DIR=#{Shellwords.escape(@sandbox_dir)}"
        lines << "echo 'Replaying setup and failed CLI-visible steps for #{@failed_index}'"
        @steps.first(@failed_index.to_i).each do |step|
          lines.concat(emit_step(step))
        end
        lines.join("\n") + "\n"
      end

      def emit_step(step)
        case step.kind
        when "cli", "json_assert"
          emit_cli(step)
        when "seed_state"
          emit_seed_state(step)
        when "write_file"
          emit_write_file(step)
        when "register_project"
          emit_register_project(step)
        when "ruby_block"
          emit_ruby_block(step)
        when "state_assert", "log_assert"
          [ "# step #{step.position} #{step.kind}: read-only assertion replayed implicitly" ]
        when *LIVE_TMUX_KINDS
          [ "# step #{step.position} skipped: requires live tmux (kind=#{step.kind})" ]
        else
          [ "# step #{step.position} skipped: kind=#{step.kind} (stateful)" ]
        end
      end

      def emit_cli(step)
        args = Array(step.args["args"]).map(&:to_s)
        [ Shellwords.join([ RbConfig.ruby, "-Ilib", "bin/hive", *args ]) ]
      end

      def emit_seed_state(step)
        # Best-effort offline replay: rebuild the seeded state file under the
        # sandbox's stages directory. Caller-supplied `content` is replayed
        # verbatim; unset values fall back to the StepExecutor defaults so the
        # marker the live run wrote is preserved.
        stage = step.args.fetch("stage").to_s
        slug = (step.args["slug"] || "scenario-task").to_s
        state_file = step.args["state_file"] || default_state_file(stage)
        marker = stage == "1-inbox" ? "WAITING" : "COMPLETE"
        content = step.args["content"] || "# #{slug}\n\n<!-- #{marker} -->\n"
        # Sub-paths beneath $HIVE_SANDBOX_DIR are emitted as double-quoted
        # strings so the shell expands the env var without us needing to
        # backslash-escape every $ — Shellwords.escape would mangle that.
        # The stage/slug components are scenario-author-controlled and YAML-
        # validated, so they're safe to interpolate directly.
        folder = "\"$HIVE_SANDBOX_DIR/.hive-state/stages/#{stage}/#{slug}\""
        lines = [
          "# step #{step.position} seed_state: #{stage}/#{slug}",
          "mkdir -p #{folder}",
          heredoc_write_unquoted("$HIVE_SANDBOX_DIR/.hive-state/stages/#{stage}/#{slug}/#{state_file}", content)
        ]
        Array(step.args["files"]).each do |spec|
          rel = spec.fetch("path")
          full = "$HIVE_SANDBOX_DIR/.hive-state/stages/#{stage}/#{slug}/#{rel}"
          lines << "mkdir -p \"#{File.dirname(full)}\""
          lines << heredoc_write_unquoted(full, spec.fetch("content", ""))
        end
        lines
      end

      def emit_write_file(step)
        path = step.args.fetch("path").to_s
        content = step.args.fetch("content").to_s
        full = path.start_with?("/") ? path : "$HIVE_SANDBOX_DIR/#{path}"
        [
          "# step #{step.position} write_file: #{path}",
          "mkdir -p \"#{File.dirname(full)}\"",
          heredoc_write_unquoted(full, content)
        ]
      end

      def emit_register_project(step)
        # Mirror Sandbox#register_secondary: copy the sample project into a
        # sibling dir under run_dir, init git, then `bin/hive init`. Run-dir
        # is the parent of HIVE_SANDBOX_DIR per SandboxEnv layout. Path
        # uses bash double-quoting to keep the $(dirname ...) substitution
        # readable; project name is scenario-author controlled.
        name = step.args.fetch("name").to_s
        sample = "test/e2e/sample-project"
        target = "\"$(dirname \"$HIVE_SANDBOX_DIR\")/#{name}\""
        [
          "# step #{step.position} register_project: #{name}",
          "rm -rf #{target}",
          "cp -a #{Shellwords.escape(sample)} #{target}",
          "( cd #{target} && git init -b master --quiet " \
            "&& git config user.email test@example.com && git config user.name 'Hive E2E' " \
            "&& git config commit.gpgsign false && git add -A && git commit -m initial --quiet )",
          "( cd #{target} && #{Shellwords.escape(RbConfig.ruby)} -Ilib bin/hive init )"
        ]
      end

      def emit_ruby_block(step)
        block = step.args.fetch("block").to_s
        [
          "# step #{step.position} ruby_block:",
          "# ruby_block runs in a stripped binding (no StepExecutor self); blocks referencing private methods won't replay.",
          "#{Shellwords.escape(RbConfig.ruby)} -e #{Shellwords.escape(block)}"
        ]
      end

      def heredoc_write_unquoted(path, content)
        # `path` is interpolated bare so $-variables (e.g. $HIVE_SANDBOX_DIR)
        # expand. The redirect is wrapped in double-quotes for whitespace
        # safety. The body uses a quoted sentinel ('MARKER') so heredoc
        # contents are NOT shell-expanded.
        marker = "HIVE_REPRO_EOF_#{Process.pid}"
        body = content.end_with?("\n") ? content : "#{content}\n"
        "cat > \"#{path}\" <<'#{marker}'\n#{body}#{marker}"
      end

      def default_state_file(stage)
        case stage
        when "1-inbox" then "idea.md"
        when "2-brainstorm" then "brainstorm.md"
        when "3-plan" then "plan.md"
        else "task.md"
        end
      end
    end
  end
end
