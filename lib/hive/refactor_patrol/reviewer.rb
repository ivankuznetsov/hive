require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "hive"
require "hive/refactor_patrol/review_agent_runner"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis_normalizer"
require "hive/patrol/review_error_details"
require "hive/patrol/source_reader"
require "hive/stages/base"

module Hive
  module RefactorPatrol
    # Per-feature review orchestration: render the review prompt, run the
    # agent, parse its output, and record errors. What counts as an acceptable
    # thesis is ThesisNormalizer's job; how the agent is spawned is
    # ReviewAgentRunner's.
    class Reviewer
      MAX_PROMPT_OWNED_FILES = 4
      MAX_PROMPT_CONTEXT_FILES = 4
      MAX_PROMPT_SOURCE_BYTES = 32 * 1024
      TemplateBindings = Struct.new(
        :project_root, :feature, :leverage, :commands, :output_path,
        :max_theses, :source_pr, :output_mode, :user_supplied_tag,
        :min_leverage_score,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      attr_reader :review_errors, :feature_results

      def initialize(project_root, cfg:, state: StateStore.new(project_root), agent_runner: nil, dry_run: false,
                     source_pr: nil, read_only: false, monotonic_clock: nil,
                     token_budget: nil, audit_context: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @dry_run = dry_run
        @source_pr = source_pr
        @read_only = read_only
        @audit_context = audit_context
        @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @agent_runner = agent_runner ||
                        ReviewAgentRunner.new(
                          project_root: @project_root, cfg: cfg, state: state,
                          dry_run: dry_run, read_only: read_only,
                          token_budget: token_budget
                        )
        @review_errors = []
        @feature_results = []
        @prompt_source_reader = Hive::Patrol::SourceReader.new(@project_root)
        @normalizer = ThesisNormalizer.new(
          project_root: @project_root,
          commands: configured_commands,
          min_leverage_score: @cfg.dig("refactor_patrol", "min_leverage_score") || 0.25
        )
      end

      def call(features, leverage_by_feature: {})
        @review_errors = []
        @feature_results = []
        remaining = max_theses_per_run
        deadline = monotonic_now + max_review_seconds_per_run
        theses = []
        features.each do |feature|
          break unless remaining.positive?

          leverage = leverage_by_feature.fetch(feature.id, {})
          unless potentially_actionable?(leverage)
            feature_theses = []
            result = feature_result(feature, feature_theses, [])
            @feature_results << result
            yield feature, feature_theses, result if block_given?
            next
          end

          remaining_seconds = deadline - monotonic_now
          unless remaining_seconds.positive?
            feature_theses = record_feature_error(
              feature, "run_deadline_exceeded",
              "refactor patrol review exceeded its #{max_review_seconds_per_run}s whole-run deadline"
            )
            result = feature_result(feature, feature_theses, @review_errors.last(1))
            @feature_results << result
            yield feature, feature_theses, result if block_given?
            break
          end

          error_offset = @review_errors.length
          limit = [ max_theses, remaining ].min
          feature_theses = review_feature(
            feature, leverage,
            max_theses: limit, timeout_sec: remaining_seconds
          )
          remaining -= feature_theses.size
          errors = @review_errors.drop(error_offset)
          result = feature_result(feature, feature_theses, errors)
          @feature_results << result
          yield feature, feature_theses, result if block_given?
          theses.concat(feature_theses)
          break if errors.any?
        end
        theses
      end

      private

      def review_feature(feature, leverage, max_theses:, timeout_sec:)
        # In dry-run mode we must not create durable artifacts under
        # .hive-state/refactor_patrol/; scratch the agent output in a temp dir.
        run_dir = @dry_run ? Dir.mktmpdir("refactor-patrol-review") : @state.run_dir("review")
        write_audit_context(run_dir, feature)
        output_path = File.join(run_dir, "theses.json")
        prompt = render_prompt(feature, leverage, output_path, max_theses: max_theses)
        result = @agent_runner.call(
          feature: feature, prompt: prompt, output_path: output_path,
          run_dir: run_dir, timeout_sec: timeout_sec
        )
        if agent_failed?(result)
          return record_feature_error(
            feature, "agent_failed", agent_error_message(result),
            Hive::Patrol::ReviewErrorDetails.from_agent_result(result)
          )
        end

        parse_theses(feature, leverage, output_path, max_theses: max_theses)
      rescue JSON::ParserError => e
        record_feature_error(feature, "malformed_json", e.message)
      rescue StandardError => e
        record_feature_error(feature, "review_error", "#{e.class}: #{e.message}")
      ensure
        FileUtils.remove_entry(run_dir) if @dry_run && run_dir && File.directory?(run_dir)
      end

      def write_audit_context(run_dir, feature)
        return if @dry_run || !@audit_context

        @state.write_json(
          File.join(run_dir, "review-context.json"),
          @audit_context.merge("feature_id" => feature.id.to_s, "feature_kind" => feature.kind.to_s)
        )
      end

      def render_prompt(feature, leverage, output_path, max_theses:)
        Hive::Stages::Base.render(
          "refactor_patrol_review_prompt.md.erb",
          TemplateBindings.new(
            project_root: @project_root,
            feature: bounded_prompt_feature(feature),
            leverage: leverage,
            commands: configured_commands,
            output_path: output_path,
            max_theses: max_theses,
            source_pr: @source_pr,
            output_mode: @read_only ? "final_message" : "output_file",
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
            min_leverage_score: min_leverage_score
          )
        )
      end

      def parse_theses(feature, leverage, output_path, max_theses:)
        doc = JSON.parse(File.read(output_path))
        unless doc.is_a?(Hash) && doc.keys == [ "theses" ] && doc.fetch("theses").is_a?(Array)
          return record_feature_error(
            feature, "schema_invalid", "reviewer output must be an object containing only a theses array"
          )
        end
        items = doc.fetch("theses")
        if items.size > max_theses
          return record_feature_error(
            feature, "schema_invalid",
            "reviewer returned #{items.size} theses; maximum for this slice is #{max_theses}"
          )
        end
        unless items.all? { |item| item.is_a?(Hash) }
          return record_feature_error(feature, "schema_invalid", "every thesis must be an object")
        end

        items.filter_map.with_index do |raw, idx|
          result = @normalizer.call(feature: feature, leverage: leverage, raw: raw, index: idx)
          if result.is_a?(ThesisNormalizer::Invalid)
            record_feature_error(feature, "schema_invalid", result.errors.join("; "))
            nil
          else
            result
          end
        end
      end

      # Hotspot measurement and evidence validation use the complete mapped
      # component. The model gets a smaller initial view so a high-leverage
      # component does not spend its architecture allowance reading every file
      # before it can form a hypothesis; its bounded follow-up can request a
      # direct dependency when the initial evidence warrants one.
      def bounded_prompt_feature(feature)
        feature.dup.tap do |bounded|
          bounded.owned_files = bounded_owned_files(feature.owned_files)
          bounded.context_files = bounded_context_paths(feature.context_files)
          bounded.tests = bounded_context_paths(feature.tests)
        end
      end

      def bounded_context_paths(paths)
        Array(paths).map(&:to_s).reject(&:empty?).uniq.first(MAX_PROMPT_CONTEXT_FILES)
      end

      def bounded_owned_files(paths)
        remaining = MAX_PROMPT_SOURCE_BYTES
        selected = []
        Array(paths).each do |path|
          break if selected.size >= MAX_PROMPT_OWNED_FILES

          bytes = @prompt_source_reader.read_bytes(path, limit: remaining + 1).bytesize
          if selected.empty? || bytes <= remaining
            selected << path
            remaining = [ remaining - bytes, 0 ].max
          end
        end
        selected
      end

      def agent_failed?(result)
        result.is_a?(Hash) && result[:status] == :error
      end

      def agent_error_message(result)
        result.is_a?(Hash) ? result[:error_message].to_s : ""
      end

      def record_feature_error(feature, kind, message, details = {})
        error = { "feature_id" => feature.id, "error" => kind, "message" => message }.merge(details)
        @review_errors << error
        unless @dry_run
          @state.write_run_log("review-error-#{SecureRandom.hex(4)}", error)
        end
        []
      end

      def feature_result(feature, theses, errors)
        {
          "feature_id" => feature.id.to_s,
          "complete" => errors.empty?,
          "thesis_ids" => theses.map { |thesis| thesis.id.to_s },
          "errors" => JSON.parse(JSON.generate(errors))
        }
      end

      def monotonic_now
        Float(@monotonic_clock.call)
      end

      def configured_commands
        (@cfg.dig("refactor_patrol", "commands") || {}).select { |_name, command| command }
      end

      def max_theses
        @cfg.dig("refactor_patrol", "max_theses_per_feature") || 1
      end

      def max_theses_per_run
        @cfg.dig("refactor_patrol", "max_theses_per_run") || 10
      end

      def max_review_seconds_per_run
        @cfg.dig("refactor_patrol", "max_review_seconds_per_run") || 3600
      end

      def min_leverage_score
        (@cfg.dig("refactor_patrol", "min_leverage_score") || 0.25).to_f
      end

      # Proposal relief is bounded at 1.0, so it cannot score higher than the
      # complete measured feature hotspot.
      def potentially_actionable?(leverage)
        return true if leverage.dig("measurement", "status") == "incomplete"

        breakdown = leverage["breakdown"]
        return true unless breakdown.is_a?(Hash) && breakdown.values.all? { |value| value.is_a?(Numeric) }

        drivers = Leverage::SIGNALS.filter_map do |signal|
          next unless breakdown.key?(signal)

          { "signal" => signal, "relief" => 1.0, "mechanism" => "maximum possible relief" }
        end
        Leverage.score_proposal(leverage, drivers).fetch("score") >= min_leverage_score
      end
    end
  end
end
