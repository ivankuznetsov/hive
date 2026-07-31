require "fileutils"
require "json"
require "rbconfig"
require "shellwords"
require_relative "paths"
require_relative "path_safety"
require_relative "sandbox_env"
require_relative "scenario_parser"
require_relative "string_expander"

module Hive
  module E2E
    class ReproScriptWriter
      LIVE_TMUX_KINDS = ScenarioParser::TMUX_STEP_KINDS

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
        SandboxEnv::LEAKY_KEYS.each { |key| lines << "unset #{key}" }
        env.each { |key, value| lines << "export #{key}=#{Shellwords.escape(value.to_s)}" }
        # Setup-step replay (seed_state / write_file / register_project)
        # references the sandbox by an explicit env var so the heredoc bodies
        # stay readable — neither SandboxEnv.repro_env nor the shell otherwise
        # carries the path through.
        lines << "export HIVE_SANDBOX_DIR=#{Shellwords.escape(@sandbox_dir)}"
        # Harness teardown parity: the executor TERMs the releases-stub thread
        # and every background process at scenario exit so they never outlive
        # the run. Mirror that here so an aborted repro doesn't leak a daemon
        # listening on the sandbox lock or a stub holding an ephemeral port.
        lines.concat(harness_teardown_prelude)
        lines << "echo 'Replaying setup and failed CLI-visible steps for #{@failed_index}'"
        replayed_steps = @steps.first(@failed_index.to_i)
        replayed_steps.each do |step|
          lines.concat(emit_step(step))
        end
        if replayed_steps.any? { |step| step.kind == "script_gh" }
          lines << "_hive_repro_cleanup"
          lines.concat(emit_gh_verification)
        end
        lines.join("\n") + "\n"
      end

      # Bash plumbing for cross-step harness state (background PIDs, stub
      # server pid + URL file). Registered once at the top of the script so
      # later step emissions can append PIDs and the EXIT trap reaps them all.
      def harness_teardown_prelude
        [
          "HIVE_REPRO_BG_PIDS=()",
          "HIVE_REPRO_STUB_PID=",
          "HIVE_REPRO_STUB_URL_FILE=",
          "_hive_repro_cleanup() {",
          "  local pid",
          "  for pid in \"${HIVE_REPRO_BG_PIDS[@]}\"; do",
          "    [ -z \"$pid\" ] && continue",
          "    kill -TERM -\"$pid\" 2>/dev/null || true",
          "  done",
          "  sleep 0.3 2>/dev/null || true",
          "  for pid in \"${HIVE_REPRO_BG_PIDS[@]}\"; do",
          "    [ -z \"$pid\" ] && continue",
          "    kill -KILL -\"$pid\" 2>/dev/null || true",
          "  done",
          "  if [ -n \"$HIVE_REPRO_STUB_PID\" ]; then",
          "    kill -TERM \"$HIVE_REPRO_STUB_PID\" 2>/dev/null || true",
          "  fi",
          "  if [ -n \"$HIVE_REPRO_STUB_URL_FILE\" ] && [ -f \"$HIVE_REPRO_STUB_URL_FILE\" ]; then",
          "    rm -f \"$HIVE_REPRO_STUB_URL_FILE\"",
          "  fi",
          "}",
          "trap _hive_repro_cleanup EXIT"
        ]
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
        when "start_releases_stub"
          emit_start_releases_stub(step)
        when "script_gh"
          emit_script_gh(step)
        when "spawn_background"
          emit_spawn_background(step)
        when "stop_process"
          emit_stop_process(step)
        when "patrol_evidence"
          emit_patrol_evidence(step)
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
        env = SandboxEnv.merge(
          SandboxEnv.repro_env(@sandbox_dir, @run_home),
          expand(step.args["env"] || {}).merge(env_overrides)
        )
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
        full = PathSafety.contained_path_any!([ @sandbox_dir, @run_home ], path, "write_file path")
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

      # Launch ReleasesStubServer in a Ruby child, then export HIVE_RELEASES_API_URL.
      # The child writes its ephemeral URL to a tempfile so this shell can poll
      # for readiness without a sleep — same condition-wait discipline as the
      # live harness. The stub pid + url file are captured into globals so the
      # EXIT trap (see harness_teardown_prelude) reaps them.
      def emit_start_releases_stub(step)
        tag = expand_string(step.args.fetch("tag").to_s)
        ruby_body = stub_server_ruby_body
        [
          "# step #{step.position} start_releases_stub: tag=#{tag}",
          # If a previous step already started a stub, stop it first — the
          # executor calls @ctx.harness_state[:releases_stub]&.stop before
          # replacing the slot.
          "if [ -n \"$HIVE_REPRO_STUB_PID\" ]; then",
          "  kill -TERM \"$HIVE_REPRO_STUB_PID\" 2>/dev/null || true",
          "  HIVE_REPRO_STUB_PID=",
          "fi",
          "HIVE_REPRO_STUB_URL_FILE=$(mktemp -t hive_repro_stub_url.XXXXXX)",
          ": > \"$HIVE_REPRO_STUB_URL_FILE\"",
          "#{Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", "-I#{File.join(Paths.e2e_root, 'lib')}", "-e", ruby_body, tag ])} \"$HIVE_REPRO_STUB_URL_FILE\" &",
          "HIVE_REPRO_STUB_PID=$!",
          # Bounded condition-wait on the URL file: 10s @ 50ms ticks.
          "for _i in $(seq 1 200); do",
          "  if [ -s \"$HIVE_REPRO_STUB_URL_FILE\" ]; then break; fi",
          "  sleep 0.05",
          "done",
          "if [ ! -s \"$HIVE_REPRO_STUB_URL_FILE\" ]; then",
          "  echo 'step #{step.position} start_releases_stub: stub url never published' >&2",
          "  exit 1",
          "fi",
          "export HIVE_RELEASES_API_URL=\"$(cat \"$HIVE_REPRO_STUB_URL_FILE\")\""
        ]
      end

      def emit_script_gh(step)
        interactions = expand(step.args.fetch("interactions"))
        ruby = [
          "require 'json'",
          "require 'gh_stub'",
          "stub = Hive::E2E::GhStub.new(ARGV.fetch(1))",
          "FileUtils.rm_rf(stub.root)",
          "stub.install(JSON.parse(ARGV.fetch(0)))"
        ].join("\n")
        [
          "# step #{step.position} script_gh: #{interactions.size} interaction(s)",
          Shellwords.join([ RbConfig.ruby, "-I#{File.join(Paths.e2e_root, 'lib')}", "-e", ruby,
                            JSON.generate(interactions), @run_home ])
        ]
      end

      def emit_gh_verification
        ruby = [
          "require 'gh_stub'",
          "Hive::E2E::GhStub.new(ARGV.fetch(0)).verify!"
        ].join("\n")
        [
          "# verify the complete default-deny GitHub transcript",
          Shellwords.join([ RbConfig.ruby, "-I#{File.join(Paths.e2e_root, 'lib')}", "-e", ruby, @run_home ])
        ]
      end

      # Bash for `hive <args> &` matching BackgroundProcess: own pgroup
      # (`setsid`), captured logs under run_home/background/<id>.log, the
      # caller's env merged onto SandboxEnv, and HIVE_RELEASES_API_URL
      # auto-injected from the active stub when the scenario didn't pin it
      # explicitly — mirrors step_executor.rb step_spawn_background.
      def emit_spawn_background(step)
        id_raw = expand_string(step.args.fetch("id").to_s)
        id = PathSafety.safe_basename!(id_raw, "spawn_background id")
        args = expand(step.args.fetch("args")).map(&:to_s)
        env = SandboxEnv.merge(
          SandboxEnv.repro_env(@sandbox_dir, @run_home),
          expand(step.args["env"] || {})
        )
        log_path = File.join(@run_home, "background", "#{id}.log")
        var = bg_pid_var(id)
        env_assignments = env.map { |key, value| "#{key}=#{value}" }
        # Match executor: if the caller didn't pin it and a stub is running,
        # auto-inject HIVE_RELEASES_API_URL=$HIVE_RELEASES_API_URL at runtime.
        injected = env.key?("HIVE_RELEASES_API_URL") ? "" : " ${HIVE_RELEASES_API_URL:+HIVE_RELEASES_API_URL=$HIVE_RELEASES_API_URL}"
        command = Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, *args ])
        env_prefix = env_assignments.empty? ? "" : "#{Shellwords.join([ "env", *env_assignments ])} "
        [
          "# step #{step.position} spawn_background id=#{id}: hive #{args.join(' ')}",
          "mkdir -p #{Shellwords.escape(File.dirname(log_path))}",
          # `setsid` gives the child its own session+pgroup so `kill -TERM -$PID`
          # signals the whole tree, matching BackgroundProcess#stop's `pgroup: true`.
          # `< /dev/null` detaches stdin so the daemon never blocks on a dead tty.
          "setsid #{env_prefix}env#{injected} #{command} > #{Shellwords.escape(log_path)} 2>&1 < /dev/null &",
          "#{var}=$!",
          "HIVE_REPRO_BG_PIDS+=(\"$#{var}\")"
        ]
      end

      # Mirrors BackgroundProcess#stop: TERM the pgroup, brief grace, KILL.
      def emit_stop_process(step)
        id_raw = expand_string(step.args.fetch("id").to_s)
        id = PathSafety.safe_basename!(id_raw, "stop_process id")
        var = bg_pid_var(id)
        [
          "# step #{step.position} stop_process id=#{id}",
          "if [ -n \"${#{var}:-}\" ]; then",
          "  kill -TERM -\"$#{var}\" 2>/dev/null || true",
          "  sleep 0.5",
          "  kill -KILL -\"$#{var}\" 2>/dev/null || true",
          "  #{var}=",
          "fi"
        ]
      end

      def emit_patrol_evidence(step)
        artifacts_root = File.join(
          @scenario_dir, "patrol-evidence"
        )
        ruby = [
          "require 'patrol_qualification_runner'",
          "result = Hive::E2E::PatrolQualificationRunner.new.call(",
          "  project_root: ARGV.fetch(0),",
          "  run_home: ARGV.fetch(1),",
          "  artifacts_root: ARGV.fetch(2)",
          ")",
          "abort(\"patrol evidence outcome is not a complete result: \#{result.inspect}\") unless",
          "  result.is_a?(Hash) &&",
          "  Hive::E2E::PatrolQualificationRunner.harness_complete?(result)"
        ].join("\n")
        [
          "# step #{step.position} patrol_evidence",
          Shellwords.join([
            RbConfig.ruby,
            "-I#{Paths.lib_dir}",
            "-I#{File.join(Paths.e2e_root, 'lib')}",
            "-e",
            ruby,
            @sandbox_dir,
            @run_home,
            artifacts_root
          ])
        ]
      end

      # Map a step id (already validated as a safe basename, but may contain
      # dashes/dots) to a bash-legal variable name. Use a stable suffix the
      # paired stop_process step can rederive.
      def bg_pid_var(id)
        "HIVE_REPRO_BG_PID_#{id.tr('-.', '_').upcase}"
      end

      # The stub server lives in test/e2e/lib/releases_stub_server.rb. The Ruby
      # child requires it, starts it on an ephemeral port, writes the URL to
      # ARGV[1] so the parent shell can read it, and then sleeps until TERM —
      # matching the executor's "stop on scenario teardown" semantics.
      #
      # NOTE on exit semantics: the live harness calls server.stop from the
      # same process that created it, so the serve thread closes cleanly. Here
      # the server runs in its own process and TERM is delivered while the
      # accept loop blocks on a syscall — calling Ruby code from that signal
      # handler can crash a Ruby 3.x child (TCPServer accept + signal-raised
      # IOError race). Use `exit!` to bypass at-exit hooks and let the OS
      # close the socket; the listener is short-lived and never persists state.
      def stub_server_ruby_body
        <<~RUBY.strip
          require 'releases_stub_server'
          tag = ARGV[0]
          url_file = ARGV[1]
          server = Hive::E2E::ReleasesStubServer.new(tag: tag)
          File.write(url_file, server.url)
          trap('TERM') { exit!(0) }
          trap('INT')  { exit!(0) }
          sleep
        RUBY
      end

      def emit_assertion(step)
        path = PathSafety.contained_path_any!([ @sandbox_dir, @run_home ], expand_string(step.args.fetch("path").to_s), "#{step.kind} path")
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
        env = SandboxEnv.merge(
          SandboxEnv.repro_env(@sandbox_dir, @run_home),
          expand(step.args["env"] || {})
        )
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
          "cfg['claude'] ||= {}",
          "cfg['claude']['mode'] = 'headless'",
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

        # `pick.inspect` produces a Ruby array literal like `["a", "b"]` which
        # itself contains double quotes. The earlier emission interpolated it
        # *into* a Ruby double-quoted string (`"expected #{pick.inspect}..."`)
        # so the inner `"` terminated the outer literal and the generated
        # ruby -e refused to parse. Bind the inspected array to a local first,
        # then interpolate the local — its inspect output reuses the safe
        # `#{... .inspect}` pattern that already works for the other values.
        [
          "pick = #{pick.inspect}",
          "actual_value = pick.reduce(doc) { |value, key| key.is_a?(Integer) ? value.fetch(key) : value.fetch(key.to_s) }",
          "expected_value = #{equals.inspect}",
          "abort(\"expected \#{pick.inspect} to equal \#{expected_value.inspect}, got \#{actual_value.inspect}\") unless actual_value == expected_value"
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
        PathSafety.contained_path_any!([ @sandbox_dir, @run_home ], expand_string(value.to_s), "scenario path")
      end
    end
  end
end
