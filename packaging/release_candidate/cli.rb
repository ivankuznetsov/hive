# frozen_string_literal: true

require "json"
require "optparse"
require_relative "runner"

module HiveReleaseCandidate
  class CLI
    VERBS = %w[plan list run inspect resume rerun dispatch collect].freeze

    def initialize(argv:, repo_root:, stdout: $stdout, stderr: $stderr, runner: nil,
                   remote_client: nil)
      @argv = argv.dup
      @json_requested = @argv.include?("--json")
      @repo_root = repo_root
      @stdout = stdout
      @stderr = stderr
      @runner = runner
      @remote_client = remote_client
    end

    def call
      options, verb = parse
      return 0 if options[:help]

      reject_irrelevant_options!(verb, options)
      result = execute(verb, options)
      emit(result, json: options[:json])
      exit_for(verb, result)
    rescue OptionParser::ParseError, UsageError => e
      emit_error(e, json: json_requested?, exit_code: 64, kind: "usage")
      64
    rescue Error => e
      emit_error(e, json: json_requested?, exit_code: e.exit_code, kind: e.kind)
      e.exit_code
    rescue StandardError => e
      emit_error(e, json: json_requested?, exit_code: 70, kind: "software")
      70
    end

    private

    def parse
      json = false
      @argv.delete_if do |arg|
        next false unless arg == "--json"

        json = true
      end
      verb = @argv.first && VERBS.include?(@argv.first) ? @argv.shift : "plan"
      if @argv.first && !@argv.first.start_with?("-")
        raise UsageError, "unknown candidate command #{@argv.first.inspect}"
      end

      options = {
        json: json,
        gates: [],
        failed: false,
        missing: false
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: bin/hive-release-candidate [verb] [options]"
        opts.on("--sha SHA") { |value| options[:sha] = value }
        opts.on("--attempt ATTEMPT") { |value| options[:attempt] = value }
        opts.on("--gate NAME") { |value| options[:gates] << value }
        opts.on("--failed") { options[:failed] = true }
        opts.on("--missing") { options[:missing] = true }
        opts.on("--workflow-run RUN_ID") { |value| options[:workflow_run] = value }
        opts.on("--retry-workflow-run RUN_ID") { |value| options[:retry_workflow_run] = value }
        opts.on("--retry-attempt ATTEMPT") { |value| options[:retry_attempt] = value }
        opts.on("--request REQUEST_ID") { |value| options[:request] = value }
        opts.on("--wait") { options[:wait] = true }
        opts.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
        opts.on("-h", "--help") { options[:help] = opts.to_s }
      end
      parser.parse!(@argv)
      raise UsageError, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      if options[:help]
        @stdout.puts(options[:help])
      end

      [ options, verb ]
    end

    def execute(verb, options)
      runner = @runner || Runner.new(
        repo_root: @repo_root,
        runs_root: ENV["HIVE_RELEASE_CANDIDATES_ROOT"],
        remote_client: @remote_client
      )
      case verb
      when "plan"
        runner.plan(ref: options[:sha])
      when "list"
        require_sha!(options)
        runner.list(ref: options[:sha])
      when "run"
        require_sha!(options)
        runner.run(ref: options[:sha], gates: options[:gates])
      when "inspect"
        require_sha!(options)
        runner.inspect(ref: options[:sha], attempt_id: require_attempt!(options))
      when "resume"
        require_sha!(options)
        runner.resume(ref: options[:sha], attempt_id: require_attempt!(options))
      when "rerun"
        require_sha!(options)
        mode = rerun_mode!(options)
        runner.rerun(
          ref: options[:sha], attempt_id: require_attempt!(options),
          mode: mode, gates: options[:gates]
        )
      when "dispatch"
        dispatch(runner, options)
      when "collect"
        collect(runner, options)
      else
        raise UsageError, "unknown candidate command #{verb.inspect}"
      end
    end

    def dispatch(runner, options)
      if !options[:sha] && !options[:retry_workflow_run]
        raise UsageError, "dispatch requires --sha or --retry-workflow-run"
      end
      if options[:sha] && options[:retry_workflow_run]
        raise UsageError, "dispatch accepts only one of --sha or --retry-workflow-run"
      end
      if options[:retry_workflow_run]
        raise UsageError, "--retry-attempt is required" if options[:retry_attempt].to_s.empty?
        mode = rerun_mode!(options)
        selector = { "mode" => mode, "gates" => options[:gates] }
        runner.dispatch(
          retry_run_id: options[:retry_workflow_run],
          retry_attempt: options[:retry_attempt],
          selector: selector
        )
      else
        unless options[:gates].empty? && !options[:failed] && !options[:missing] &&
               options[:retry_attempt].nil?
          raise UsageError, "new dispatch does not accept retry selectors"
        end
        runner.dispatch(ref: options[:sha])
      end
    end

    def collect(runner, options)
      if options[:workflow_run].to_s.empty? == options[:request].to_s.empty?
        raise UsageError, "collect requires --workflow-run or --request"
      end
      if options[:workflow_run] && options[:attempt].to_s.empty?
        raise UsageError, "collect --workflow-run requires --attempt"
      end
      runner.collect(
        workflow_run: options[:workflow_run], request: options[:request],
        attempt: options[:attempt], wait: !!options[:wait],
        timeout: options[:timeout]
      )
    end

    def require_sha!(options)
      raise UsageError, "--sha is required" if options[:sha].to_s.empty?
    end

    def require_attempt!(options)
      raise UsageError, "--attempt is required" if options[:attempt].to_s.empty?

      options[:attempt]
    end

    def rerun_mode!(options)
      modes = []
      modes << "failed" if options[:failed]
      modes << "missing" if options[:missing]
      modes << "named" unless options[:gates].empty?
      unless modes.size == 1
        raise UsageError, "rerun requires exactly one of --failed, --missing, or --gate"
      end
      modes.first
    end

    def reject_irrelevant_options!(verb, options)
      allowed = {
        "plan" => %i[json sha help],
        "list" => %i[json sha help],
        "run" => %i[json sha gates help],
        "inspect" => %i[json sha attempt help],
        "resume" => %i[json sha attempt help],
        "rerun" => %i[json sha attempt gates failed missing help],
        "dispatch" => %i[
          json sha gates failed missing retry_workflow_run retry_attempt help
        ],
        "collect" => %i[json workflow_run request attempt wait timeout help]
      }.fetch(verb)
      active = options.filter_map do |key, value|
        next if value.nil? || value == false || value == [] || key == :json && value == false

        key
      end
      unexpected = active - allowed
      return if unexpected.empty?

      flags = unexpected.map { |key| "--#{key.to_s.tr('_', '-')}" }
      raise UsageError, "#{verb} does not accept #{flags.join(', ')}"
    end

    def emit(result, json:)
      if json
        @stdout.puts(JSON.generate(result))
      else
        @stdout.write(human(result))
      end
    end

    def human(result)
      case result["schema"]
      when "hive-release-candidate-plan"
        fetches = result.dig("baseline_cache", "fetch_argv").to_a.map do |argv|
          "  #{argv.join(' ')}"
        end
        next_action = result.dig("baseline_cache", "next_action_argv")
        <<~TEXT
          Candidate: #{result.fetch("candidate_sha")} (#{result.fetch("candidate_version")})
          Dirty checkout: #{result.fetch("dirty_checkout")}
          Scope: #{result.fetch("scope_status")}
          QA: #{result.fetch("qa_status")}
          Blockers: #{result.fetch("blockers").join(", ")}
          Run: #{result.fetch("run_argv").join(" ")}
          Baseline fetches:
          #{fetches.empty? ? "  none" : fetches.join("\n")}
          Hosted baseline proof: #{next_action ? next_action.join(" ") : "not required"}
        TEXT
      when "hive-release-candidate-list"
        rows = result.fetch("attempts").map do |attempt|
          marker = attempt.fetch("current") ? " current" : ""
          "#{attempt.fetch('attempt_id')}#{marker} #{attempt.fetch('scope_status')} #{attempt.fetch('qa_status')}"
        end
        "#{rows.empty? ? 'No attempts.' : rows.join("\n")}\n"
      when Evidence::EVIDENCE_SCHEMA
        Evidence.new(paths: Paths.new(
          repo_root: @repo_root,
          candidate_sha: result.fetch("candidate_sha"),
          runs_root: ENV["HIVE_RELEASE_CANDIDATES_ROOT"]
        )).render_summary(result)
      else
        result.map { |key, value| "#{key}: #{value.is_a?(Array) ? value.join(', ') : value}" }.join("\n") + "\n"
      end
    end

    def exit_for(verb, result)
      return 75 if verb == "collect" && result["status"] == "timeout"
      return 0 unless %w[run resume rerun].include?(verb)

      case result.fetch("scope_status")
      when "passed" then 0
      when "failed" then 1
      when "partial" then 75
      else 69
      end
    end

    def emit_error(error, json:, exit_code:, kind:)
      if json
        @stdout.puts(JSON.generate(
          {
            "schema" => "hive-release-candidate-error",
            "schema_version" => SCHEMA_VERSION,
            "ok" => false,
            "error_kind" => kind,
            "message" => error.message,
            "exit_code" => exit_code
          }
        ))
      else
        @stderr.puts("hive-release-candidate: #{error.message}")
      end
    end

    def json_requested?
      @json_requested
    end
  end
end
