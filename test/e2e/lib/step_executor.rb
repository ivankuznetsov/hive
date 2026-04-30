require "fileutils"
require "json"
require "time"
require "yaml"
require "hive/lock"
require "hive/markers"
require_relative "artifact_capture"
require_relative "cli_driver"
require_relative "diff_walker"
require_relative "json_validator"
require_relative "paths"
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
        attr_reader :step, :schema_diff

        def initialize(step, message, schema_diff: nil)
          @step = step
          @schema_diff = schema_diff
          super(message)
        end
      end

      def initialize(scenario:, sandbox:, scenario_dir:, run_id:)
        @scenario = scenario
        @sandbox = sandbox
        @scenario_dir = scenario_dir
        @run_id = run_id
        @ctx = ScenarioContext.new(sandbox: sandbox, run_home: sandbox.run_home, run_id: run_id)
        @cli = CliDriver.new(@ctx.sandbox_dir, @ctx.run_home)
        @validator = JsonValidator.new
        @diff_walker = DiffWalker.new
        @tmux_lifecycle = TmuxSessionLifecycle.new(scenario: scenario, sandbox_dir: @ctx.sandbox_dir,
                                                   run_home: @ctx.run_home, run_id: run_id,
                                                   scenario_dir: scenario_dir)
        @step_results = []
        @preserve_cast = false
      end

      # Scenario `setup:` is intentionally minimal in v1. Multi-stage dispatch
      # for fake-claude responses is driven by per-step `env:` overrides
      # (HIVE_FAKE_CLAUDE_WRITE_FILE / HIVE_FAKE_CLAUDE_WRITE_CONTENT, see
      # full_pipeline_happy_path.yml). Multi-reviewer-per-invocation queueing
      # is post-v1; see wiki/gaps.md for the open question.
      def execute
        started = monotonic_time
        @scenario.steps.each { |step| dispatch(step) }
        @tmux_lifecycle.stop_asciinema(delete: true)
        ScenarioResult.new(name: @scenario.name, status: "passed",
                           duration_seconds: (monotonic_time - started).round(3),
                           failed_step_index: nil, failed_step_kind: nil, error_summary: nil,
                           artifacts_dir: relative_scenario_dir, repro: nil)
      rescue StandardError => e
        on_failure(e, started)
      ensure
        @tmux_lifecycle.stop_asciinema(delete: !@preserve_cast)
        @tmux_lifecycle.cleanup
      end

      private

      def dispatch(step)
        send("step_#{step.kind}", step)
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "passed" }
      rescue StepFailure
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "failed" }
        raise
      rescue StandardError => e
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "failed" }
        raise StepFailure.new(step, e.message)
      end

      def on_failure(error, started)
        @preserve_cast = true
        @tmux_lifecycle.stop_asciinema(delete: false)
        failed_step = error.respond_to?(:step) ? error.step : nil
        repro = ReproScriptWriter.new(scenario_dir: @scenario_dir, sandbox_dir: @ctx.sandbox_dir,
                                      run_home: @ctx.run_home, steps: @scenario.steps,
                                      failed_index: failed_step&.position || @step_results.size + 1).write
        ArtifactCapture.new(scenario_dir: @scenario_dir, sandbox_dir: @ctx.sandbox_dir, run_home: @ctx.run_home)
          .collect(error: error, failed_step: failed_step, step_results: @step_results,
                   tmux_driver: @tmux_lifecycle.tmux,
                   schema_diff: error.respond_to?(:schema_diff) ? error.schema_diff : nil,
                   pane_before: @ctx.pre_keystroke_pane)
        ScenarioResult.new(name: @scenario.name, status: "failed",
                           duration_seconds: (monotonic_time - started).round(3),
                           failed_step_index: failed_step&.position, failed_step_kind: failed_step&.kind,
                           error_summary: "#{error.class}: #{error.message}",
                           artifacts_dir: relative_scenario_dir,
                           repro: repro.sub("#{File.dirname(@scenario_dir)}/", ""))
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
        stage = expand_string(step.args.fetch("stage"))
        slug = expand_string(step.args["slug"] || "#{@scenario.name.tr('_', '-')}-task")
        @ctx.slug_default!(slug)
        folder = File.join(project_dir, ".hive-state", "stages", stage, slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, step.args["state_file"] || default_state_file(stage))
        File.write(state_file, expand_string(step.args["content"] || default_state_content(slug, stage)))
        Array(step.args["files"]).each do |file_spec|
          path = File.join(folder, expand_string(file_spec.fetch("path")))
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
        if step.args.key?("text")
          tmux.send_text(expand_string(step.args["text"]))
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
        raise StepFailure.new(step, "log file not found: #{path}") unless File.exist?(path)

        regex = Regexp.new(expand_string(step.args.fetch("match")))
        raise StepFailure.new(step, "expected #{path} to match #{regex.inspect}") unless File.read(path).match?(regex)
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
          raise StepFailure.new(step, "expected #{path} to be absent") if File.exist?(path)
          return
        end
        if step.args.key?("exists") || step.args.key?("marker") || step.args.key?("contains") || step.args.key?("match")
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
        expanded = expand_string(value.to_s)
        expanded.start_with?("/") ? expanded : File.join(@ctx.sandbox_dir, expanded)
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
        @scenario_dir.sub("#{Paths.runs_dir}/", "")
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
