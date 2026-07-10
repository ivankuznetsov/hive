require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "hive"
require "hive/refactor_patrol/review_agent_runner"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis_normalizer"
require "hive/stages/base"

module Hive
  module RefactorPatrol
    # Per-feature review orchestration: render the review prompt, run the
    # agent, parse its output, and record errors. What counts as an acceptable
    # thesis is ThesisNormalizer's job; how the agent is spawned is
    # ReviewAgentRunner's.
    class Reviewer
      TemplateBindings = Struct.new(
        :project_root, :feature, :leverage, :commands, :output_path,
        :max_theses, :source_pr, :output_mode, :user_supplied_tag,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      attr_reader :review_errors

      def initialize(project_root, cfg:, state: StateStore.new(project_root), agent_runner: nil, dry_run: false,
                     source_pr: nil, read_only: false)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @dry_run = dry_run
        @source_pr = source_pr
        @read_only = read_only
        @agent_runner = agent_runner ||
                        ReviewAgentRunner.new(
                          project_root: @project_root, cfg: cfg, state: state,
                          dry_run: dry_run, read_only: read_only
                        )
        @review_errors = []
        @normalizer = ThesisNormalizer.new(project_root: @project_root, commands: configured_commands)
      end

      def call(features, leverage_by_feature: {})
        features.flat_map do |feature|
          review_feature(feature, leverage_by_feature.fetch(feature.id, {}))
        end
      end

      private

      def review_feature(feature, leverage)
        # In dry-run mode we must not create durable artifacts under
        # .hive-state/refactor_patrol/; scratch the agent output in a temp dir.
        run_dir = @dry_run ? Dir.mktmpdir("refactor-patrol-review") : @state.run_dir("review")
        output_path = File.join(run_dir, "theses.json")
        prompt = render_prompt(feature, leverage, output_path)
        result = @agent_runner.call(feature: feature, prompt: prompt, output_path: output_path, run_dir: run_dir)
        return record_feature_error(feature, "agent_failed", agent_error_message(result)) if agent_failed?(result)

        parse_theses(feature, leverage, output_path)
      rescue JSON::ParserError => e
        record_feature_error(feature, "malformed_json", e.message)
      rescue StandardError => e
        record_feature_error(feature, "review_error", "#{e.class}: #{e.message}")
      ensure
        FileUtils.remove_entry(run_dir) if @dry_run && run_dir && File.directory?(run_dir)
      end

      def render_prompt(feature, leverage, output_path)
        Hive::Stages::Base.render(
          "refactor_patrol_review_prompt.md.erb",
          TemplateBindings.new(
            project_root: @project_root,
            feature: feature,
            leverage: leverage,
            commands: configured_commands,
            output_path: output_path,
            max_theses: max_theses,
            source_pr: @source_pr,
            output_mode: @read_only ? "final_message" : "output_file",
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def parse_theses(feature, leverage, output_path)
        doc = JSON.parse(File.read(output_path))
        items = doc.is_a?(Hash) ? doc.fetch("theses", []) : doc
        Array(items).first(max_theses).filter_map.with_index do |raw, idx|
          result = @normalizer.call(feature: feature, leverage: leverage, raw: raw, index: idx)
          if result.is_a?(ThesisNormalizer::Invalid)
            record_feature_error(feature, "schema_invalid", result.errors.join("; "))
            nil
          else
            result
          end
        end
      end

      def agent_failed?(result)
        result.is_a?(Hash) && result[:status] == :error
      end

      def agent_error_message(result)
        result.is_a?(Hash) ? result[:error_message].to_s : ""
      end

      def record_feature_error(feature, kind, message)
        @review_errors << { "feature_id" => feature.id, "error" => kind, "message" => message }
        unless @dry_run
          @state.write_run_log("review-error-#{SecureRandom.hex(4)}", {
            "feature_id" => feature.id,
            "error" => kind,
            "message" => message
          })
        end
        []
      end

      def configured_commands
        (@cfg.dig("refactor_patrol", "commands") || {}).select { |_name, command| command }
      end

      def max_theses
        @cfg.dig("refactor_patrol", "max_theses_per_feature") || 3
      end
    end
  end
end
