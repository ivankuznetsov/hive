require "fileutils"
require "json"
require "time"
require "yaml"
require "hive/lock"
require "hive/markers"
require "hive/stages"
require_relative "artifact_capture"
require_relative "background_process"
require_relative "cli_driver"
require_relative "releases_stub_server"
require_relative "diff_walker"
require_relative "gh_stub"
require_relative "json_validator"
require_relative "paths"
require_relative "path_safety"
require_relative "patrol_qualification_runner"
require_relative "repro_script_writer"
require_relative "sandbox"
require_relative "sandbox_env"
require_relative "scenario_context"
require_relative "string_expander"
require_relative "tmux_session_lifecycle"

module Hive
  module E2E
    # Dispatch hub: walks a parsed scenario, sends each step to a `step_<kind>`
    # handler, accumulates per-step status, and on failure produces a repro.sh
    # plus a forensic artifact bundle. State that needs to outlive a single
    # step (slug, registered projects, pre-keystroke pane snapshot) lives on
    # the ScenarioContext; string expansion is delegated to StringExpander;
    # tmux + asciinema lifecycle is owned by TmuxSessionLifecycle.
    class StepExecutor
      ScenarioResult = Data.define(:name, :status, :duration_seconds, :failed_step_index, :failed_step_kind, :error_summary, :artifacts_dir, :repro)

      class StepFailure < StandardError
        attr_reader :step, :schema_diff, :stdout, :stderr, :exit_actual, :exit_expected

        def initialize(step, message, schema_diff: nil, stdout: nil, stderr: nil,
                       exit_actual: nil, exit_expected: nil)
          @step = step
          @schema_diff = schema_diff
          @stdout = stdout
          @stderr = stderr
          @exit_actual = exit_actual
          @exit_expected = exit_expected
          super(message)
        end
      end

      def initialize(scenario:, sandbox:, scenario_dir:, run_id:)
        @scenario = scenario
        @sandbox = sandbox
        @scenario_dir = scenario_dir
        @run_dir = File.dirname(File.dirname(scenario_dir))
        @run_id = run_id
        @ctx = ScenarioContext.new(sandbox: sandbox, run_home: sandbox.run_home, run_id: run_id)
        @cli = CliDriver.new(@ctx.sandbox_dir, @ctx.run_home)
        @validator = JsonValidator.new
        @diff_walker = DiffWalker.new
        @tmux_lifecycle = TmuxSessionLifecycle.new(scenario: scenario, sandbox_dir: @ctx.sandbox_dir,
                                                   run_home: @ctx.run_home, run_id: run_id,
                                                   scenario_dir: scenario_dir, context: @ctx)
        @step_results = []
        @preserve_cast = false
        @gh_stub = GhStub.new(@ctx.run_home)
      end

      # Scenario `setup:` is intentionally minimal in v1. Multi-stage dispatch
      # for fake-claude responses is driven by per-step `env:` overrides
      # (HIVE_FAKE_CLAUDE_WRITE_FILE / HIVE_FAKE_CLAUDE_WRITE_CONTENT, see
      # full_pipeline_happy_path.yml). Multi-reviewer-per-invocation queueing
      # is post-v1; see wiki/gaps.md for the open question.
      def execute
        started = monotonic_time
        tmux_evidence = nil
        @scenario.steps.each { |step| dispatch(step) }
        # Quiesce every producer before validating the transcript. Otherwise a
        # daemon or TUI child can issue a late gh call after verify! succeeds.
        # Capture live-only pane evidence first in case verification itself
        # fails, then synchronously terminate tmux before reading the audit.
        tmux_evidence = @tmux_lifecycle.failure_evidence
        quiesce_harness(preserve_cast: true)
        @gh_stub.verify!
        @tmux_lifecycle.discard_preserved_cast
        ScenarioResult.new(name: @scenario.name, status: "passed",
                           duration_seconds: (monotonic_time - started).round(3),
                           failed_step_index: nil, failed_step_kind: nil, error_summary: nil,
                           artifacts_dir: File.directory?(@scenario_dir) ? relative_scenario_dir : nil,
                           repro: nil)
      rescue StandardError => e
        # Freeze logs and GitHub evidence before building the failure bundle.
        @preserve_cast = true
        tmux_evidence ||= @tmux_lifecycle.failure_evidence
        quiesce_harness(preserve_cast: true, raise_errors: false)
        on_failure(e, started, tmux_evidence: tmux_evidence)
      ensure
        quiesce_harness(preserve_cast: @preserve_cast, raise_errors: false)
        @tmux_lifecycle.discard_preserved_cast unless @preserve_cast
      end

      private

      # Reap any long-lived processes / stub servers a scenario started, so they
      # never outlive the scenario (TERM the daemon/bot pgroup, close the stub).
      # Each stop is rescued independently so one failure can't abandon the rest.
      def teardown_harness_processes
        (@ctx.harness_state[:background] || {}).each_value { |proc| safe_stop(proc) }
        safe_stop(@ctx.harness_state[:releases_stub])
      end

      def quiesce_harness(preserve_cast:, raise_errors: true)
        errors = []
        begin
          @tmux_lifecycle.stop_asciinema(delete: !preserve_cast)
        rescue StandardError => e
          errors << e
        end
        begin
          @tmux_lifecycle.cleanup
        rescue StandardError => e
          errors << e
        end
        teardown_harness_processes
        raise errors.first if raise_errors && errors.any?

        errors
      end

      def safe_stop(stoppable)
        stoppable&.stop
      rescue StandardError
        nil
      end

      def dispatch(step)
        send("step_#{step.kind}", step)
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "passed" }
      rescue StepFailure
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "failed" }
        raise
      rescue StandardError => e
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "failed" }
        # Preserve subprocess output from CliDriver errors so the artifact
        # bundle and any agent reading exception.txt sees the actual command
        # stdout/stderr that triggered the failure. Without this, the wrap
        # at step level reduces a "hive run exit 75 with stderr 'lock held'"
        # to a bare exception message — agents lose the diagnostic surface.
        case e
        when CliDriver::ExitMismatchError
          raise StepFailure.new(step, e.message,
                                stdout: e.stdout, stderr: e.stderr,
                                exit_actual: e.actual, exit_expected: e.expected)
        when CliDriver::StderrMismatchError
          raise StepFailure.new(step, e.message, stdout: e.stdout, stderr: e.stderr)
        else
          raise StepFailure.new(step, e.message)
        end
      end

      def on_failure(error, started, tmux_evidence:)
        failed_step = error.respond_to?(:step) ? error.step : nil
        repro = ReproScriptWriter.new(scenario_dir: @scenario_dir, sandbox_dir: @ctx.sandbox_dir,
                                      run_home: @ctx.run_home, steps: @scenario.steps,
                                      failed_index: failed_step&.position || @step_results.size + 1,
                                      scenario_name: @scenario.name,
                                      coverage_id: @scenario.coverage.primary,
                                      expander_context: repro_expander_context).write
        ArtifactCapture.new(scenario_dir: @scenario_dir, sandbox_dir: @ctx.sandbox_dir, run_home: @ctx.run_home,
                            tui_log_dir: @tmux_lifecycle.tui_log_dir)
          .collect(error: error, failed_step: failed_step, step_results: @step_results,
                   tmux_keystrokes: tmux_evidence[:tmux_keystrokes],
                   pane_after: tmux_evidence[:pane_after],
                   schema_diff: error.respond_to?(:schema_diff) ? error.schema_diff : nil,
                   pane_before: @ctx.pre_keystroke_pane)
        ScenarioResult.new(name: @scenario.name, status: "failed",
                           duration_seconds: (monotonic_time - started).round(3),
                           failed_step_index: failed_step&.position, failed_step_kind: failed_step&.kind,
                           error_summary: "#{error.class}: #{error.message}",
                           artifacts_dir: relative_scenario_dir,
                           repro: repro.sub("#{@run_dir}/", ""))
      end

      # ---- step kinds ----------------------------------------------------

      def step_cli(step)
        run_cli_step(step)
        discover_slug!
      end

      def step_json_assert(step)
        result = run_cli_step(step)
        validation = @validator.validate(step.args.fetch("schema"), result.stdout)
        raise StepFailure.new(step, "no schema for #{step.args.fetch('schema')}") if validation.status == :no_schema
        unless validation.ok?
          diff = @diff_walker.render(validation.errors, parse_error: validation.parse_error)
          raise StepFailure.new(step, "schema validation failed for #{step.args.fetch('schema')}", schema_diff: diff)
        end

        doc = JSON.parse(result.stdout)
        @ctx.last_json = doc
        return unless step.args.key?("pick")

        actual = pick(doc, Array(step.args["pick"]))
        expected = expand(step.args["equals"])
        return if actual == expected

        raise StepFailure.new(step, "expected #{step.args['pick'].inspect} to equal #{expected.inspect}, got #{actual.inspect}")
      end

      def step_state_assert(step)
        path = expand_path(step.args.fetch("path"))
        deadline = Time.now + (step.args["timeout"] || 0).to_f
        loop do
          return if state_assertion_passes?(step, path)
          break if Time.now >= deadline

          sleep 0.2
        end

        run_state_assertion!(step, path)
      end

      def step_seed_state(step)
        project_dir = project_dir_for(step.args["project"])
        stage = safe_stage!(expand_string(step.args.fetch("stage")), step)
        slug = PathSafety.safe_basename!(expand_string(step.args["slug"] || "#{@scenario.name.tr('_', '-')}-task"), "seed_state slug")
        @ctx.slug_default!(slug)
        folder = File.join(project_dir, ".hive-state", "stages", stage, slug)
        FileUtils.mkdir_p(folder)
        state_file = contained_relative_path(folder, step.args["state_file"] || default_state_file(stage), "seed_state state_file")
        File.write(state_file, expand_string(step.args["content"] || default_state_content(slug, stage)))
        Array(step.args["files"]).each do |file_spec|
          path = contained_relative_path(folder, file_spec.fetch("path"), "seed_state file path")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, expand_string(file_spec.fetch("content", "")))
        end
      end

      def step_write_file(step)
        path = expand_path(step.args.fetch("path"))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, expand_string(step.args.fetch("content")))
      end

      def step_register_project(step)
        name = expand_string(step.args.fetch("name"))
        @ctx.register_project(name, @sandbox.register_secondary(name))
      end

      # DANGER: ruby_block runs eval(...) with full process privileges. The
      # binding exposes self (StepExecutor) plus sandbox/slug/run_home locals.
      # Scenarios authored here can mutate the outer hive checkout, exec
      # arbitrary system commands, and access any private method or ivar of
      # this class. The trust boundary is "anyone who can commit to
      # test/e2e/scenarios/ can execute arbitrary code at test-runtime."
      # Use sparingly; prefer a purpose-built step kind for repeating patterns.
      def step_ruby_block(step)
        sandbox = @ctx.sandbox_dir
        slug = current_slug
        run_home = @ctx.run_home
        eval(step.args.fetch("block"), binding, @scenario.path, step.position)
        @ctx.slug_default!(slug)
      end

      def step_tui_expect(step)
        tmux = @tmux_lifecycle.start_session
        # require_stable forces tmux_driver to take a second confirming capture
        # before returning so we don't race a still-rendering TUI frame.
        tmux.wait_for(anchor: expand_string(step.args.fetch("anchor")),
                      timeout: (step.args["timeout"] || 3.0).to_f,
                      allow_stable: false,
                      require_stable: true)
      end

      def step_tui_keys(step)
        tmux = @tmux_lifecycle.start_session
        # Snapshot the pane BEFORE the keystroke so a step failure has a
        # before/after pair for forensics. Best-effort.
        @ctx.pre_keystroke_pane = @tmux_lifecycle.snapshot_pane
        tmux.mark_subprocess_log!
        if step.args.key?("text")
          text = expand_string(step.args["text"])
          truthy?(step.args["paste"]) ? tmux.send_text_chunk(text) : tmux.send_text(text)
        else
          # `keys:` always carries a tmux named-key token (e.g. "Enter", "Up",
          # "C-c"); send it verbatim. Literal text uses the `text:` branch above.
          tmux.send_keys(expand_string(step.args["keys"].to_s))
        end
      end

      def step_wait_subprocess(step)
        tmux = @tmux_lifecycle.start_session
        tmux.wait_for_subprocess_exit(timeout: (step.args["timeout"] || 30.0).to_f)
      end

      def step_editor_action(step)
        run_cli_step(step, env_overrides: { "EDITOR" => Paths.editor_shim })
      end

      def step_log_assert(step)
        path = expand_path(step.args.fetch("path"))
        regex = Regexp.new(expand_string(step.args.fetch("match")))
        # Optional polling: a long-lived process (e.g. the bot) writes its log
        # asynchronously, so wait up to `timeout` for the line to appear — an
        # explicit condition wait, not a fixed sleep.
        deadline = Time.now + (step.args["timeout"] || 0).to_f
        loop do
          return if File.exist?(path) && File.read(path).match?(regex)
          break if Time.now >= deadline

          sleep 0.2
        end
        raise StepFailure.new(step, "log file not found: #{path}") unless File.exist?(path)

        raise StepFailure.new(step, "expected #{path} to match #{regex.inspect}")
      end

      def step_start_releases_stub(step)
        tag = expand_string(step.args.fetch("tag"))
        @ctx.harness_state[:releases_stub]&.stop
        @ctx.harness_state[:releases_stub] = ReleasesStubServer.new(tag: tag)
      end

      def step_script_gh(step)
        @gh_stub.install(expand(step.args.fetch("interactions")))
      end

      def step_patrol_evidence(step)
        root = PathSafety.contained_path!(
          @scenario_dir,
          File.join(@scenario_dir, "patrol-evidence"),
          "patrol_evidence artifacts root"
        )
        runner = @patrol_evidence_runner ||
          PatrolQualificationRunner.new
        result = runner.call(
          project_root: @ctx.sandbox_dir,
          run_home: @ctx.run_home,
          artifacts_root: root
        )
        run_id = result["run_id"] if result.is_a?(Hash)
        artifacts_dir =
          result["artifacts_dir"] if result.is_a?(Hash)
        expected_artifacts = if
          PatrolQualificationRunner::RUN_ID.match?(run_id.to_s)
          File.join(root, run_id)
        end
        unless result.is_a?(Hash) &&
               artifacts_dir == expected_artifacts &&
               PathSafety.contained?(root, artifacts_dir) &&
               PatrolQualificationRunner.coverage_complete?(
                 result,
                 coverage_id: @scenario.coverage.primary
               )
          status = result.is_a?(Hash) ?
            result["status"].to_s : "malformed"
          raise StepFailure.new(
            step,
            "patrol evidence outcome #{status.inspect} is not a complete result"
          )
        end
      rescue ArgumentError => e
        raise StepFailure.new(step, e.message)
      end

      def step_spawn_background(step)
        id = expand_string(step.args.fetch("id"))
        args = expand(step.args.fetch("args"))
        env = expand(step.args["env"] || {})
        # Auto-inject the running stub's URL so scenarios don't have to thread
        # an ephemeral port through; an explicit env entry still wins.
        if (stub = @ctx.harness_state[:releases_stub]) && !env.key?("HIVE_RELEASES_API_URL")
          env = env.merge("HIVE_RELEASES_API_URL" => stub.url)
        end
        procs = (@ctx.harness_state[:background] ||= {})
        procs[id]&.stop
        procs[id] = BackgroundProcess.new(
          args: args, sandbox_dir: @ctx.sandbox_dir, run_home: @ctx.run_home,
          env: env, log_path: File.join(@ctx.run_home, "background", "#{id}.log")
        ).start
      end

      def step_stop_process(step)
        id = expand_string(step.args.fetch("id"))
        proc = (@ctx.harness_state[:background] || {})[id]
        raise StepFailure.new(step, "no background process #{id.inspect}") unless proc

        proc.stop
      end

      def step_tui_refute(step)
        tmux = @tmux_lifecycle.start_session
        anchor = expand_string(step.args.fetch("anchor"))
        deadline = monotonic_time + (step.args["timeout"] || 2.0).to_f
        # Assert absence only on a STABLE frame (two equal captures), so we
        # don't pass on a mid-render frame that simply hasn't drawn it yet.
        previous = nil
        loop do
          pane = tmux.capture_pane
          if pane == previous
            raise StepFailure.new(step, "expected TUI to NOT contain #{anchor.inspect}") if pane.include?(anchor)
            return
          end
          previous = pane
          break if monotonic_time >= deadline

          sleep 0.1
        end
        raise StepFailure.new(step, "expected TUI to NOT contain #{anchor.inspect}") if previous.to_s.include?(anchor)
      end

      # ---- helpers -------------------------------------------------------

      def run_cli_step(step, env_overrides: {})
        args = expand(step.args.fetch("args"))
        env = expand(step.args["env"] || {}).merge(env_overrides)
        cwd = expand_path(step.args["cwd"] || "{sandbox}")
        @cli.call(args,
                  expect_exit: step.args.fetch("expect_exit", 0),
                  expect_stderr_match: step.args["expect_stderr_match"],
                  cwd: cwd,
                  timeout: (step.args["timeout"] || 30.0).to_f,
                  env_overrides: env)
      end

      def state_assertion_passes?(step, path)
        run_state_assertion!(step, path)
        true
      rescue StepFailure
        false
      end

      def run_state_assertion!(step, path)
        if truthy?(step.args["absent"])
          exists = truthy?(step.args["glob"]) ? Dir.glob(path).any? : File.exist?(path)
          raise StepFailure.new(step, "expected #{path} to be absent") if exists
          return
        end
        path = state_assert_target(step, path)
        if !truthy?(step.args["absent"]) || step.args.key?("exists") || step.args.key?("marker") || step.args.key?("contains") || step.args.key?("match")
          raise StepFailure.new(step, "expected #{path} to exist") unless File.exist?(path)
        end
        if (marker = step.args["marker"])
          expected = marker.fetch("current").to_s.downcase
          actual = Hive::Markers.current(path).name.to_s
          raise StepFailure.new(step, "expected marker #{expected}, got #{actual}") unless actual == expected
        end
        if step.args["contains"]
          body = File.read(path)
          expected = expand_string(step.args["contains"].to_s)
          raise StepFailure.new(step, "expected #{path} to contain #{expected.inspect}") unless body.include?(expected)
        end
        return unless step.args["match"]

        body = File.read(path)
        regex = Regexp.new(expand_string(step.args["match"].to_s))
        raise StepFailure.new(step, "expected #{path} to match #{regex.inspect}") unless body.match?(regex)
      end

      def state_assert_target(step, path)
        return path unless truthy?(step.args["glob"])

        Dir.glob(path).sort.first || path
      end

      def discover_slug!
        @ctx.slug_default!(current_slug)
      rescue StepFailure
        nil
      end

      def current_slug
        return @ctx.slug if @ctx.slug

        stages = Dir[File.join(@ctx.sandbox_dir, ".hive-state", "stages", "*", "*")].select { |path| File.directory?(path) }
        raise StepFailure.new(nil, "no task slug found in sandbox") if stages.empty?

        @ctx.slug_default!(File.basename(stages.sort.first))
        @ctx.slug
      end

      def project_dir_for(name)
        return @ctx.sandbox_dir if name.nil?

        @ctx.project_dir(expand_string(name.to_s))
      end

      def default_state_file(stage)
        case stage
        when "1-inbox" then "idea.md"
        when "2-brainstorm" then "brainstorm.md"
        when "3-plan" then "plan.md"
        else "task.md"
        end
      end

      def default_state_content(slug, stage)
        marker = stage == "1-inbox" ? "WAITING" : "COMPLETE"
        "# #{slug}\n\n<!-- #{marker} -->\n"
      end

      def pick(doc, path)
        path.reduce(doc) do |value, key|
          key.is_a?(Integer) ? value.fetch(key) : value.fetch(key.to_s)
        end
      end

      def expand_path(value)
        # Allow the sandbox project dir OR its HIVE_HOME (run_home) — both are
        # test-controlled. The update flow's state (update_check.json) and the
        # install-channel marker live under run_home, a sibling of the project.
        PathSafety.contained_path_any!([ @ctx.sandbox_dir, @ctx.run_home ], expand_string(value.to_s), "scenario path")
      end

      def contained_relative_path(root, value, label)
        relative = PathSafety.relative_path!(expand_string(value.to_s), label)
        PathSafety.contained_path!(root, relative, label)
      end

      def safe_stage!(stage, step)
        return stage if Hive::Stages::DIRS.include?(stage)

        raise StepFailure.new(step, "unknown stage #{stage.inspect}")
      end

      def expand(value)
        StringExpander.expand(value, expander_context)
      end

      def expand_string(value)
        StringExpander.expand_string(value.to_s, expander_context)
      end

      def expander_context
        @ctx.expander_context(slug_resolver: -> { current_slug_safe })
      end

      def current_slug_safe
        current_slug
      rescue StandardError
        ""
      end

      def truthy?(value)
        value == true || value.to_s == "true"
      end

      def relative_scenario_dir
        @scenario_dir.sub("#{@run_dir}/", "")
      end

      def repro_expander_context
        @ctx.expander_context(slug_resolver: -> { @ctx.slug.to_s })
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
