require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "paths"
require_relative "path_safety"
require_relative "sandbox_env"
require_relative "string_expander"

module Hive
  module E2E
    class ReproScriptWriter
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
        lines = [
          "#!/usr/bin/env bash",
          "set -euo pipefail",
          "cd #{Shellwords.escape(Paths.repo_root)}"
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
        when "cli"
          emit_cli(step)
        when "json_assert"
          emit_json_assert(step)
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
          emit_assertion(step)
        when *LIVE_TMUX_KINDS
          [ "# step #{step.position} skipped: requires live tmux (kind=#{step.kind})" ]
        else
          [ "# step #{step.position} skipped: kind=#{step.kind} (stateful)" ]
        end
      rescue ArgumentError => e
        [
          "# step #{step.position} not replayable: unsafe #{step.kind} input",
          "echo #{Shellwords.escape("step #{step.position} not replayable: #{e.message}")} >&2",
          "exit 1"
        ]
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
        # Every path is resolved and validated before becoming a shell
        # argument; the generated script never interpolates raw scenario path
        # components into shell syntax.
        stage = safe_stage(stage)
        slug = PathSafety.safe_basename!(slug, "seed_state slug")
        project_root = project_root_for(step.args["project"])
        folder = File.join(project_root, ".hive-state", "stages", stage, slug)
        lines = [
          "# step #{step.position} seed_state: #{stage}/#{slug}",
          "mkdir -p #{Shellwords.escape(folder)}",
          heredoc_write(contained_relative_path(folder, state_file, "seed_state state_file"), content)
        ]
        Array(step.args["files"]).each do |spec|
          rel = expand_string(spec.fetch("path"))
          full = contained_relative_path(folder, rel, "seed_state file path")
          lines << "mkdir -p #{Shellwords.escape(File.dirname(full))}"
          lines << heredoc_write(full, expand_string(spec.fetch("content", "")))
        end
        lines
      end

      def emit_write_file(step)
        path = expand_string(step.args.fetch("path").to_s)
        content = expand_string(step.args.fetch("content").to_s)
        full = PathSafety.contained_path!(@sandbox_dir, path, "write_file path")
        [
          "# step #{step.position} write_file: #{path}",
          "mkdir -p #{Shellwords.escape(File.dirname(full))}",
          heredoc_write(full, content)
        ]
      end

      def emit_register_project(step)
        # Mirror Sandbox#register_secondary: copy the sample project into a
        # sibling dir under run_dir, init git, then `bin/hive init`. Run-dir
        # is the parent of HIVE_SANDBOX_DIR per SandboxEnv layout.
        name = PathSafety.safe_basename!(expand_string(step.args.fetch("name").to_s), "register_project name")
        sample = Paths.sample_project
        target = direct_run_child(name, "register_project target")
        [
          "# step #{step.position} register_project: #{name}",
          "rm -rf #{Shellwords.escape(target)}",
          "cp -a #{Shellwords.escape(sample)} #{Shellwords.escape(target)}",
          "( cd #{Shellwords.escape(target)} && git init -b master --quiet " \
            "&& git config user.email test@example.com && git config user.name 'Hive E2E' " \
            "&& git config commit.gpgsign false && git add -A && git commit -m initial --quiet )",
          "( cd #{Shellwords.escape(target)} && #{Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, "init" ])} )",
          tune_project_config_command(target)
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
          Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", "-e", ruby ])
        ]
      end

      def emit_assertion(step)
        path = PathSafety.contained_path!(@sandbox_dir, expand_string(step.args.fetch("path").to_s), "#{step.kind} path")
        ruby = case step.kind
        when "state_assert" then state_assert_ruby(step, path)
        when "log_assert" then log_assert_ruby(step, path)
        end
        [
          "# step #{step.position} #{step.kind}: #{path}",
          Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", "-e", ruby ])
        ]
      end

      def emit_json_assert(step)
        args = expand(step.args.fetch("args")).map(&:to_s)
        env = expand(step.args["env"] || {})
        cwd = PathSafety.contained_path!(@sandbox_dir, expand_string(step.args["cwd"] || "{sandbox}"), "json_assert cwd")
        expected = step.args.key?("expect_exit") ? step.args["expect_exit"] : 0
        schema_name = normalize_schema_name(step.args.fetch("schema"))
        pick = step.args.key?("pick") ? Array(step.args["pick"]) : nil
        equals = step.args.key?("equals") ? expand(step.args["equals"]) : nil
        ruby = [
          "require 'json'",
          "require 'open3'",
          "require 'json_schemer'",
          "require 'hive'",
          "require #{File.join(Paths.e2e_root, 'lib', 'schemas').inspect}",
          "env = #{env.inspect}",
          "args = #{args.inspect}",
          "cwd = #{cwd.inspect}",
          "expected = #{expected.inspect}",
          "schema_name = #{schema_name.inspect}",
          "cmd = #{[ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin ].inspect} + args",
          "out, err, status = Dir.chdir(cwd) { Open3.capture3(env, *cmd) }",
          "actual = status.exitstatus || -1",
          "abort(\"expected exit #{expected}, got \#{actual}\\n\#{err}\") unless expected.nil? || actual == expected.to_i",
          "doc = JSON.parse(out)",
          "schema_path = if Hive::Schemas::SCHEMA_VERSIONS.key?(schema_name)",
          "  Hive::Schemas.schema_path(schema_name)",
          "elsif Hive::E2E::Schemas::VERSIONS.key?(schema_name)",
          "  Hive::E2E::Schemas.schema_path(schema_name)",
          "else",
          "  abort(\"no schema for \#{schema_name}\")",
          "end",
          "errors = JSONSchemer.schema(JSON.parse(File.read(schema_path))).validate(doc).to_a",
          "abort(\"schema validation failed for #{schema_name}: \#{errors.inspect}\") unless errors.empty?",
          json_pick_ruby(pick, equals)
        ].compact.join("\n")
        [
          "# step #{step.position} json_assert: #{args.join(' ')}",
          Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", "-e", ruby ])
        ]
      end

      def state_assert_ruby(step, path)
        absent = truthy?(step.args["absent"])
        marker = step.args["marker"]
        expected_marker = marker ? marker.fetch("current").to_s.downcase : nil
        contains = step.args.key?("contains") ? expand_string(step.args["contains"].to_s) : nil
        match = step.args.key?("match") ? expand_string(step.args["match"].to_s) : nil
        timeout = (step.args["timeout"] || 0).to_f
        [
          "require 'hive/markers'",
          "path = #{path.inspect}",
          "deadline = Time.now + #{timeout.inspect}",
          "ok = false",
          "loop do",
          "  if #{absent.inspect}",
          "    ok = !File.exist?(path)",
          "  else",
          "    ok = File.exist?(path)",
          ("    ok &&= Hive::Markers.current(path).name.to_s == #{expected_marker.inspect}" if expected_marker),
          ("    ok &&= File.read(path).include?(#{contains.inspect})" if contains),
          ("    ok &&= File.read(path).match?(Regexp.new(#{match.inspect}))" if match),
          "  end",
          "  break if ok || Time.now >= deadline",
          "  sleep 0.2",
          "end",
          "abort(\"state_assert failed for #{path}\") unless ok"
        ].compact.join("\n")
      end

      def log_assert_ruby(step, path)
        match = expand_string(step.args.fetch("match").to_s)
        [
          "path = #{path.inspect}",
          "abort(\"log file not found: #{path}\") unless File.exist?(path)",
          "regex = Regexp.new(#{match.inspect})",
          "abort(\"expected #{path} to match \#{regex.inspect}\") unless File.read(path).match?(regex)"
        ].join("\n")
      end

      def heredoc_write(path, content)
        marker = "HIVE_REPRO_EOF_#{Process.pid}"
        body = content.end_with?("\n") ? content : "#{content}\n"
        "cat > #{Shellwords.escape(path)} <<'#{marker}'\n#{body}#{marker}"
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
        return @sandbox_dir if name.empty?

        direct_run_child(PathSafety.safe_basename!(name, "project name"), "project root")
      end

      def direct_run_child(name, label)
        run_dir = File.dirname(@sandbox_dir)
        path = PathSafety.contained_path!(run_dir, name, label)
        raise ArgumentError, "#{label} #{path.inspect} must be directly under #{run_dir.inspect}" unless File.dirname(path) == File.expand_path(run_dir)

        path
      end

      def contained_relative_path(root, value, label)
        relative = PathSafety.relative_path!(expand_string(value.to_s), label)
        PathSafety.contained_path!(root, relative, label)
      end

      def safe_stage(stage)
        require "hive/stages"
        return stage if Hive::Stages::DIRS.include?(stage)

        raise ArgumentError, "unknown stage #{stage.inspect}"
      end

      def tune_project_config_command(target)
        code = [
          "require 'yaml'",
          "project = ARGV.fetch(0)",
          "run_dir = ARGV.fetch(1)",
          "cfg_path = File.join(project, '.hive-state', 'config.yml')",
          "cfg = YAML.safe_load(File.read(cfg_path)) || {}",
          "cfg['worktree_root'] = File.join(run_dir, 'worktrees')",
          "cfg['review'] ||= {}",
          "cfg['review']['ci'] ||= {}",
          "cfg['review']['ci']['command'] = nil",
          "cfg['review']['reviewers'] = []",
          "cfg['review']['browser_test'] ||= {}",
          "cfg['review']['browser_test']['enabled'] = false",
          "cfg['review']['triage'] ||= {}",
          "cfg['review']['triage']['enabled'] = false",
          "File.write(cfg_path, cfg.to_yaml)"
        ].join("\n")
        Shellwords.join([ RbConfig.ruby, "-e", code, target, File.dirname(@sandbox_dir) ])
      end

      def normalize_schema_name(name)
        text = name.to_s
        text.start_with?("hive-") ? text : "hive-#{text}"
      end

      def json_pick_ruby(pick, equals)
        return nil unless pick

        [
          "actual_value = #{pick.inspect}.reduce(doc) { |value, key| key.is_a?(Integer) ? value.fetch(key) : value.fetch(key.to_s) }",
          "expected_value = #{equals.inspect}",
          "abort(\"expected #{pick.inspect} to equal \#{expected_value.inspect}, got \#{actual_value.inspect}\") unless actual_value == expected_value"
        ].join("\n")
      end

      def truthy?(value)
        value == true || value.to_s == "true"
      end

      def expand(value)
        StringExpander.expand(value, @expander_context)
      end

      def expand_string(value)
        StringExpander.expand_string(value.to_s, @expander_context)
      end

      def expand_path(value)
        expanded = expand_string(value.to_s)
        PathSafety.contained_path!(@sandbox_dir, expanded, "scenario path")
      end
    end
  end
end
