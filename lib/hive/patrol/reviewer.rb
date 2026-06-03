require "json"
require "securerandom"
require "hive/agent"
require "hive/agent_profiles"
require "hive/patrol/finding"
require "hive/patrol/fingerprint"
require "hive/patrol/runner_task"
require "hive/patrol/state_store"
require "hive/stages/base"

module Hive
  module Patrol
    class Reviewer
      VALID_CATEGORIES = %w[bug security performance documentation test-gap maintainability].freeze
      VALID_SEVERITIES = %w[critical high medium low].freeze
      VALID_CONFIDENCE = %w[high medium low].freeze

      TemplateBindings = Struct.new(
        :project_root, :feature, :output_path, :max_findings, :user_supplied_tag,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      # Features whose review failed this run (agent error, malformed
      # JSON, or any other read/parse failure). A non-empty list means the
      # scan was partial; the caller must not advance last_scanned_sha as
      # if the commit reviewed cleanly (U5 fail-loud).
      attr_reader :review_errors

      def initialize(project_root, cfg:, state: StateStore.new(project_root), agent_runner: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @agent_runner = agent_runner || method(:run_agent)
        @review_errors = []
      end

      def call(features)
        features.flat_map { |feature| review_feature(feature) }
      end

      private

      # One feature's failure must never abort the whole scan: a flaky or
      # non-zero agent (Agent#run! sets status :error rather than raising)
      # would otherwise leave no output file and the previous
      # `File.read(output_path)` raised an uncaught Errno::ENOENT through
      # `flat_map`, discarding every other feature's findings. We record
      # the error and skip just this feature, mirroring the malformed-JSON
      # path (U5).
      def review_feature(feature)
        run_dir = @state.run_dir("review")
        output_path = File.join(run_dir, "findings.json")
        prompt = render_prompt(feature, output_path)
        result = @agent_runner.call(feature: feature, prompt: prompt,
                                    output_path: output_path, run_dir: run_dir)
        if agent_failed?(result)
          return record_feature_error(feature, "agent_failed", agent_error_message(result))
        end

        parse_findings(feature, output_path)
      rescue JSON::ParserError => e
        record_feature_error(feature, "malformed_json", e.message)
      rescue StandardError => e
        record_feature_error(feature, "review_error", "#{e.class}: #{e.message}")
      end

      def agent_failed?(result)
        result.is_a?(Hash) && result[:status] == :error
      end

      def agent_error_message(result)
        result.is_a?(Hash) ? result[:error_message].to_s : ""
      end

      def record_feature_error(feature, kind, message)
        @review_errors << { "feature_id" => feature.id, "error" => kind, "message" => message }
        @state.write_run_log("review-error-#{SecureRandom.hex(4)}", {
          "feature_id" => feature.id,
          "error" => kind,
          "message" => message
        })
        []
      end

      def render_prompt(feature, output_path)
        Hive::Stages::Base.render(
          "patrol_review_prompt.md.erb",
          TemplateBindings.new(
            project_root: @project_root,
            feature: feature,
            output_path: output_path,
            max_findings: max_findings,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def parse_findings(feature, output_path)
        doc = JSON.parse(File.read(output_path))
        items = doc.is_a?(Hash) ? doc.fetch("findings", []) : doc
        Array(items).first(max_findings).filter_map.with_index do |raw, idx|
          normalize_finding(feature, raw, idx)
        end
      end

      def normalize_finding(feature, raw, idx)
        return nil unless raw.is_a?(Hash)

        category = raw["category"].to_s
        severity = raw["severity"].to_s
        confidence = raw["confidence"].to_s
        return nil unless VALID_CATEGORIES.include?(category)
        return nil unless VALID_SEVERITIES.include?(severity)
        return nil unless VALID_CONFIDENCE.include?(confidence)

        finding = Finding.new(
          id: "#{feature.id}-#{idx + 1}",
          feature_id: feature.id,
          category: category,
          severity: severity,
          confidence: confidence,
          title: raw["title"] || raw["summary"],
          description: raw["description"],
          recommendation: raw["recommendation"],
          evidence: Array(raw["evidence"])
        )
        # Stamp the fingerprint before persisting so the durable
        # findings/*.json record links back to dedup/PR state. Without
        # this the finding is written before Commands::Patrol assigns the
        # fingerprint, and Finding#to_h.compact drops the nil key —
        # leaving the audit record unlinked. Commands::Patrol stamps with
        # `||=`, so the value computed here is reused, not overwritten.
        finding.fingerprint = Fingerprint.compute(finding, project_root: @project_root)
        @state.write_finding(finding)
        finding
      end

      def run_agent(prompt:, output_path:, run_dir:, **)
        task = RunnerTask.new(
          folder: run_dir,
          project_root: @project_root,
          state_file: File.join(run_dir, "review.md"),
          log_dir: File.join(@state.root, "logs"),
          slug: "patrol-review"
        )
        profile = Hive::AgentProfiles.lookup(@cfg.dig("patrol", "agent") || "claude", cfg: @cfg)
        Hive::Agent.new(
          task: task,
          prompt: prompt,
          add_dirs: [ @project_root ],
          cwd: @project_root,
          max_budget_usd: @cfg.dig("budget_usd", "patrol") || 100,
          timeout_sec: @cfg.dig("timeout_sec", "patrol") || 3600,
          log_label: "patrol-review",
          profile: profile,
          expected_output: output_path,
          status_mode: :output_file_exists
        ).run!
      end

      def max_findings
        @cfg.dig("patrol", "max_findings_per_feature") || 10
      end
    end
  end
end
