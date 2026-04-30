require "fileutils"
require "json"
require "rbconfig"
require "shellwords"
require "time"
require "yaml"
require "hive/lock"
require "hive/markers"
require_relative "artifact_capture"
require_relative "asciinema_driver"
require_relative "cli_driver"
require_relative "diff_walker"
require_relative "json_validator"
require_relative "paths"
require_relative "repro_script_writer"
require_relative "sandbox"
require_relative "sandbox_env"
require_relative "tmux_driver"

module Hive
  module E2E
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
        @sandbox_dir = sandbox.sandbox_dir
        @run_home = sandbox.run_home
        @scenario_dir = scenario_dir
        @run_id = run_id
        @cli = CliDriver.new(@sandbox_dir, @run_home)
        @validator = JsonValidator.new
        @diff_walker = DiffWalker.new
        @step_results = []
        @slug = nil
        @projects = { File.basename(@sandbox_dir) => @sandbox_dir }
        @last_json = nil
        @tmux = nil
        @asciinema = nil
        @preserve_cast = false
      end

      def execute
        started = monotonic_time
        @scenario.steps.each do |step|
          execute_step(step)
        end
        stop_asciinema(delete: true)
        duration = monotonic_time - started
        ScenarioResult.new(name: @scenario.name, status: "passed", duration_seconds: duration.round(3),
                           failed_step_index: nil, failed_step_kind: nil, error_summary: nil,
                           artifacts_dir: relative_scenario_dir, repro: nil)
      rescue StandardError => e
        @preserve_cast = true
        stop_asciinema(delete: false)
        failed_step = e.respond_to?(:step) ? e.step : nil
        repro = ReproScriptWriter.new(
          scenario_dir: @scenario_dir,
          sandbox_dir: @sandbox_dir,
          run_home: @run_home,
          steps: @scenario.steps,
          failed_index: failed_step&.position || @step_results.size + 1
        ).write
        ArtifactCapture.new(scenario_dir: @scenario_dir, sandbox_dir: @sandbox_dir, run_home: @run_home)
          .collect(error: e, failed_step: failed_step, step_results: @step_results, tmux_driver: @tmux,
                   schema_diff: e.respond_to?(:schema_diff) ? e.schema_diff : nil)
        duration = monotonic_time - started
        ScenarioResult.new(name: @scenario.name, status: "failed", duration_seconds: duration.round(3),
                           failed_step_index: failed_step&.position, failed_step_kind: failed_step&.kind,
                           error_summary: "#{e.class}: #{e.message}",
                           artifacts_dir: relative_scenario_dir, repro: repro.sub("#{File.dirname(@scenario_dir)}/", ""))
      ensure
        stop_asciinema(delete: !@preserve_cast)
        @tmux&.cleanup
      end

      private

      def execute_step(step)
        send("step_#{step.kind}", step)
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "passed" }
      rescue StepFailure
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "failed" }
        raise
      rescue StandardError => e
        @step_results << { "index" => step.position, "kind" => step.kind, "status" => "failed" }
        raise StepFailure.new(step, e.message)
      end

      def step_cli(step)
        result = run_cli_step(step)
        discover_slug!
        result
      end

      def step_json_assert(step)
        result = run_cli_step(step)
        validation = @validator.validate(step.args.fetch("schema"), result.stdout)
        if validation.status == :no_schema
          raise StepFailure.new(step, "no schema for #{step.args.fetch('schema')}")
        end
        unless validation.ok?
          diff = @diff_walker.render(validation.errors, parse_error: validation.parse_error)
          raise StepFailure.new(step, "schema validation failed for #{step.args.fetch('schema')}", schema_diff: diff)
        end

        doc = JSON.parse(result.stdout)
        @last_json = doc
        if step.args.key?("pick")
          actual = pick(doc, Array(step.args["pick"]))
          expected = expand_value(step.args["equals"])
          raise StepFailure.new(step, "expected #{step.args['pick'].inspect} to equal #{expected.inspect}, got #{actual.inspect}") unless actual == expected
        end
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
        if step.args["match"]
          body = File.read(path)
          regex = Regexp.new(expand_string(step.args["match"].to_s))
          raise StepFailure.new(step, "expected #{path} to match #{regex.inspect}") unless body.match?(regex)
        end
      end

      def step_seed_state(step)
        project_dir = project_dir_for(step.args["project"])
        stage = expand_string(step.args.fetch("stage"))
        slug = expand_string(step.args["slug"] || "#{@scenario.name.tr('_', '-')}-task")
        @slug ||= slug
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
        @projects[name] = @sandbox.register_secondary(name)
      end

      def step_ruby_block(step)
        sandbox = @sandbox_dir
        slug = current_slug
        run_home = @run_home
        eval(step.args.fetch("block"), binding, @scenario.path, step.position)
        @slug ||= slug
      end

      def step_tui_expect(step)
        ensure_tmux!
        @tmux.wait_for(anchor: expand_string(step.args.fetch("anchor")),
                       timeout: (step.args["timeout"] || 3.0).to_f,
                       allow_stable: false)
      end

      def step_tui_keys(step)
        ensure_tmux!
        if step.args.key?("text")
          @tmux.send_text(expand_string(step.args["text"]))
        else
          keys = expand_string(step.args["keys"].to_s)
          @tmux.send_keys(keys == "Enter" ? "Enter" : keys)
        end
      end

      def step_wait_subprocess(step)
        ensure_tmux!
        @tmux.wait_for_subprocess_exit(timeout: (step.args["timeout"] || 30.0).to_f)
      end

      def step_editor_action(step)
        env = { "EDITOR" => Paths.editor_shim }
        run_cli_step(step, env_overrides: env)
      end

      def step_log_assert(step)
        path = expand_path(step.args.fetch("path"))
        raise StepFailure.new(step, "log file not found: #{path}") unless File.exist?(path)

        regex = Regexp.new(expand_string(step.args.fetch("match")))
        raise StepFailure.new(step, "expected #{path} to match #{regex.inspect}") unless File.read(path).match?(regex)
      end

      def run_cli_step(step, env_overrides: {})
        args = expand_value(step.args.fetch("args"))
        env = expand_value(step.args["env"] || {}).merge(env_overrides)
        cwd = expand_path(step.args["cwd"] || "{sandbox}")
        @cli.call(args,
                  expect_exit: step.args.fetch("expect_exit", 0),
                  expect_stderr_match: step.args["expect_stderr_match"],
                  cwd: cwd,
                  timeout: (step.args["timeout"] || 30.0).to_f,
                  env_overrides: env)
      end

      def ensure_tmux!
        return @tmux if @tmux
        raise "tmux is required for TUI e2e scenarios" unless TmuxDriver.available?

        env = SandboxEnv.repro_env(@sandbox_dir, @run_home)
        env.merge!(expand_value(@scenario.setup["tui_env"] || {}))
        command = Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, "tui" ])
        @tmux = TmuxDriver.new(run_id: @run_id, session_name: "scenario-#{@scenario.name}",
                               command: command, env: env)
        @tmux.start
        start_asciinema_if_available
      end

      def start_asciinema_if_available
        return if @asciinema
        return unless AsciinemaDriver.available?

        @asciinema = AsciinemaDriver.new(
          socket_name: @tmux.socket_name,
          session_name: @tmux.session_name,
          cast_path: File.join(@scenario_dir, "cast.json")
        )
        @asciinema.start
      rescue AsciinemaDriver::Unavailable
        @asciinema = nil
      end

      def stop_asciinema(delete:)
        return unless @asciinema

        @asciinema.stop
        if delete
          FileUtils.rm_f(@asciinema.cast_path)
        else
          FileUtils.mkdir_p(@scenario_dir)
          File.write(File.join(@scenario_dir, "cast-status.txt"), "#{@asciinema.integrity_status}\n")
        end
      ensure
        @asciinema = nil
      end

      def discover_slug!
        @slug ||= current_slug
      rescue StepFailure
        nil
      end

      def current_slug
        return @slug if @slug

        stages = Dir[File.join(@sandbox_dir, ".hive-state", "stages", "*", "*")].select { |path| File.directory?(path) }
        raise StepFailure.new(nil, "no task slug found in sandbox") if stages.empty?

        @slug = File.basename(stages.sort.first)
      end

      def project_dir_for(name)
        return @sandbox_dir if name.nil?

        @projects.fetch(expand_string(name.to_s))
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
        expanded.start_with?("/") ? expanded : File.join(@sandbox_dir, expanded)
      end

      def expand_value(value)
        case value
        when Hash then value.transform_values { |v| expand_value(v) }
        when Array then value.map { |v| expand_value(v) }
        when String then expand_string(value)
        else value
        end
      end

      def expand_string(value)
        value
          .gsub("{sandbox}", @sandbox_dir)
          .gsub("{run_home}", @run_home)
          .gsub("{project}", File.basename(@sandbox_dir))
          .gsub("{slug}", @slug || current_slug_safe.to_s)
          .gsub(/\{task_dir:([^}]+)\}/) { File.join(@sandbox_dir, ".hive-state", "stages", Regexp.last_match(1), @slug || current_slug_safe.to_s) }
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
