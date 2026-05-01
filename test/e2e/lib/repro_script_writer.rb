require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "paths"
require_relative "sandbox_env"
require_relative "string_expander"

module Hive
  module E2E
    class ReproScriptWriter
      # Step kinds whose effect is pure CLI/file/state I/O — safe to replay
      # offline. tui_keys / tui_expect / wait_subprocess need a live tmux pane
      # the bare bash repro can't bootstrap, so they're skipped with a comment.
      REPLAYABLE_KINDS = %w[
        cli json_assert seed_state write_file register_project
        ruby_block state_assert log_assert editor_action
      ].freeze

      LIVE_TMUX_KINDS = %w[tui_keys tui_expect wait_subprocess].freeze

      def initialize(scenario_dir:, sandbox_dir:, run_home:, steps:, failed_index:, scenario_name: nil, expander_context: nil)
        @scenario_dir = scenario_dir
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @steps = steps
        @failed_index = failed_index
        @scenario_name = scenario_name
        @expander_context = expander_context || {
          sandbox_dir: sandbox_dir,
          run_home: run_home,
          run_id: "",
          slug: nil,
          slug_resolver: nil
        }
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
        when "editor_action"
          emit_cli(step, env_overrides: { "EDITOR" => Paths.editor_shim })
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

      def emit_cli(step, env_overrides: {})
        args = expand(step.args.fetch("args")).map(&:to_s)
        env = expand(step.args["env"] || {}).merge(env_overrides)
        cwd = expand_path(step.args["cwd"] || "{sandbox}")
        expected = step.args.key?("expect_exit") ? step.args["expect_exit"] : 0
        # Use absolute paths for ruby's -I and bin/hive so they resolve from
        # inside the `( cd <sandbox> && ... )` subshell. The outer `cd <repo>`
        # at the script top doesn't apply within the subshell, so a relative
        # `-Ilib bin/hive` would look up paths under the sandbox and fail.
        command = Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, *args ])
        command = Shellwords.join([ "env", *env.map { |key, value| "#{key}=#{value}" } ]) + " #{command}" unless env.empty?

        lines = [
          "# step #{step.position} #{step.kind}: #{args.join(' ')}",
          "set +e",
          "( cd #{Shellwords.escape(cwd)} && #{command} )",
          "status=$?",
          "set -e"
        ]
        if expected.nil?
          lines << "true # exit status intentionally unchecked"
        else
          lines << "if [ \"$status\" -ne #{expected.to_i} ]; then echo \"expected exit #{expected.to_i}, got $status\" >&2; exit 1; fi"
        end
        lines
      end

      def emit_seed_state(step)
        # Best-effort offline replay: rebuild the seeded state file under the
        # sandbox's stages directory. Caller-supplied `content` is replayed
        # verbatim; unset values fall back to the StepExecutor defaults so the
        # marker the live run wrote is preserved.
        stage = expand_string(step.args.fetch("stage").to_s)
        slug = expand_string(step.args["slug"] || default_slug)
        state_file = expand_string(step.args["state_file"] || default_state_file(stage))
        marker = stage == "1-inbox" ? "WAITING" : "COMPLETE"
        content = expand_string(step.args["content"] || "# #{slug}\n\n<!-- #{marker} -->\n")
        # Sub-paths beneath $HIVE_SANDBOX_DIR are emitted as double-quoted
        # strings so the shell expands the env var without us needing to
        # backslash-escape every $ — Shellwords.escape would mangle that.
        # The stage/slug components are scenario-author-controlled and YAML-
        # validated, so they're safe to interpolate directly.
        project_root = project_root_for(step.args["project"])
        folder = "\"#{project_root}/.hive-state/stages/#{stage}/#{slug}\""
        lines = [
          "# step #{step.position} seed_state: #{stage}/#{slug}",
          "mkdir -p #{folder}",
          heredoc_write_unquoted("#{project_root}/.hive-state/stages/#{stage}/#{slug}/#{state_file}", content)
        ]
        Array(step.args["files"]).each do |spec|
          rel = expand_string(spec.fetch("path"))
          full = "#{project_root}/.hive-state/stages/#{stage}/#{slug}/#{rel}"
          lines << "mkdir -p \"#{File.dirname(full)}\""
          lines << heredoc_write_unquoted(full, expand_string(spec.fetch("content", "")))
        end
        lines
      end

      def emit_write_file(step)
        path = expand_string(step.args.fetch("path").to_s)
        content = expand_string(step.args.fetch("content").to_s)
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
        ruby = [
          "require 'fileutils'",
          "require 'time'",
          "require 'yaml'",
          "require 'hive/lock'",
          "sandbox = ENV.fetch('HIVE_SANDBOX_DIR')",
          "run_home = ENV.fetch('HIVE_HOME')",
          "slug = #{expand_string("{slug}").inspect}",
          block
        ].join("\n")
        [
          "# step #{step.position} ruby_block:",
          "# ruby_block runs with sandbox, run_home, and slug locals restored for replay.",
          "#{Shellwords.escape(RbConfig.ruby)} -Ilib -e #{Shellwords.escape(ruby)}"
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

      def default_slug
        return "scenario-task" unless @scenario_name

        "#{@scenario_name.tr('_', '-')}-task"
      end

      def project_root_for(project)
        name = expand_string(project.to_s)
        return "$HIVE_SANDBOX_DIR" if name.empty?

        "$(dirname \"$HIVE_SANDBOX_DIR\")/#{name}"
      end

      def expand(value)
        StringExpander.expand(value, @expander_context)
      end

      def expand_string(value)
        StringExpander.expand_string(value.to_s, @expander_context)
      end

      def expand_path(value)
        expanded = expand_string(value.to_s)
        expanded.start_with?("/") ? expanded : File.join(@sandbox_dir, expanded)
      end
    end
  end
end
