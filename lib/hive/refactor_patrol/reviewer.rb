require "fileutils"
require "json"
require "json_schemer"
require "pathname"
require "securerandom"
require "tmpdir"
require "hive"
require "hive/agent"
require "hive/agent_profiles"
require "hive/patrol/runner_task"
require "hive/refactor_patrol/fingerprint"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis"
require "hive/stages/base"
require "hive/usage_db"

module Hive
  module RefactorPatrol
    class Reviewer
      VALID_CONFIDENCE = %w[high medium low].freeze
      MEASURABLE_SIGNALS = %w[
        churn
        fan_in
        complexity
        coupling
        repeated_dependency
        bug_density
        coverage_gap
      ].freeze

      TemplateBindings = Struct.new(
        :project_root, :feature, :leverage, :commands, :output_path,
        :max_theses, :user_supplied_tag,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      attr_reader :review_errors

      def initialize(project_root, cfg:, state: StateStore.new(project_root), agent_runner: nil, dry_run: false)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @dry_run = dry_run
        @agent_runner = agent_runner || method(:run_agent)
        @review_errors = []
        @schemer = JSONSchemer.schema(Pathname.new(Hive::Schemas.schema_path("hive-refactor-patrol-thesis")))
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
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def parse_theses(feature, leverage, output_path)
        doc = JSON.parse(File.read(output_path))
        items = doc.is_a?(Hash) ? doc.fetch("theses", []) : doc
        Array(items).first(max_theses).filter_map.with_index do |raw, idx|
          normalize_thesis(feature, leverage, raw, idx)
        end
      end

      def normalize_thesis(feature, leverage, raw, idx)
        return nil unless raw.is_a?(Hash)

        hash = defaulted_hash(feature, leverage, raw, idx)
        enforce_behavior_guidance!(feature, hash)
        enforce_admissibility!(hash)
        thesis = Thesis.from_h(hash)
        thesis.fingerprint = Fingerprint.compute(thesis, project_root: @project_root)
        hash["fingerprint"] = thesis.fingerprint

        unless @schemer.valid?(hash)
          record_feature_error(feature, "schema_invalid", schema_errors(hash).join("; "))
          return nil
        end

        thesis
      end

      def defaulted_hash(feature, leverage, raw, idx)
        boundary = {
          "owned_files" => Array(feature.owned_files),
          "entrypoints" => Array(feature.entrypoints)
        }
        risk = raw["risk"].is_a?(Hash) ? raw["risk"] : {}
        required_validation = raw["required_validation"].is_a?(Hash) ? raw["required_validation"] : {}
        raw_feature = raw["feature"].is_a?(Hash) ? raw["feature"]["id"] : raw["feature"]

        {
          "id" => raw["id"].to_s.empty? ? "#{feature.id}-refactor-#{idx + 1}" : raw["id"].to_s,
          "feature_id" => feature.id.to_s,
          "feature" => raw_feature.to_s.empty? ? feature.id.to_s : raw_feature.to_s,
          "problem" => raw["problem"].to_s,
          "cost" => raw["cost"].to_s,
          "evidence" => normalize_evidence(feature, leverage, Array(raw["evidence"])),
          "proposed_refactor" => raw["proposed_refactor"].to_s.empty? ? raw["refactor"].to_s : raw["proposed_refactor"].to_s,
          "feature_boundary" => boundary.merge(raw["feature_boundary"].is_a?(Hash) ? raw["feature_boundary"] : {}),
          # R5: rank by the deterministic measured-signal blend. The agent's
          # own expected_leverage.score/breakdown is advisory only and is
          # discarded here so it cannot override the computed ranking.
          "expected_leverage" => {
            "score" => (leverage["score"] || 0).to_f,
            "breakdown" => leverage["breakdown"].is_a?(Hash) ? leverage["breakdown"] : {}
          },
          "confidence" => VALID_CONFIDENCE.include?(raw["confidence"].to_s) ? raw["confidence"].to_s : "low",
          "risk" => default_risk(risk),
          "required_validation" => {
            "commands" => Array(required_validation["commands"]),
            "characterization_first" => required_validation["characterization_first"] == true,
            "notes" => (required_validation["notes"] || required_validation["characterization_notes"]).to_s
          },
          "admissible" => raw.key?("admissible") ? raw["admissible"] == true : true,
          "admissibility_reason" => raw["admissibility_reason"].to_s,
          "follow_up_approval_state" => raw["follow_up_approval_state"].to_s.empty? ? "pending" : raw["follow_up_approval_state"].to_s,
          "fingerprint" => raw["fingerprint"].to_s
        }
      end

      # Dogfooding showed agents drift from the evidence contract in
      # predictable, recoverable ways: a plural "files" array instead of
      # "file", a named signal without the measured "value". Repair only what
      # stays honest — paths the agent itself named and values we measured —
      # so admissibility judges the substance of the evidence, not its spelling.
      def normalize_evidence(feature, leverage, items)
        items.flat_map do |item|
          next [ item ] unless item.is_a?(Hash)

          expand_evidence_files(feature, item).map { |entry| backfill_signal_value(leverage, entry) }
        end
      end

      def expand_evidence_files(feature, item)
        return [ item ] unless item["file"].to_s.strip.empty?

        files = Array(item["files"] || item["paths"] || item["path"]).map(&:to_s).reject { |f| f.strip.empty? }
        files = anchored_owned_files(feature, item) if files.empty?
        return [ item ] if files.empty?

        rest = item.reject { |key, _| %w[file files paths path].include?(key) }
        files.map { |file| rest.merge("file" => file) }
      end

      # Anchor file-less evidence to owned files only when the evidence text
      # literally names them — never invent an anchor the agent didn't cite.
      def anchored_owned_files(feature, item)
        text = "#{item["snippet"]} #{item["claim"]}"
        (Array(feature.owned_files) + Array(feature.entrypoints)).uniq.select { |path| text.include?(path) }
      end

      def backfill_signal_value(leverage, item)
        signal = item["signal"].to_s
        return item if item.key?("value") || !MEASURABLE_SIGNALS.include?(signal)

        measured = leverage.is_a?(Hash) ? leverage.dig("signals", signal) : nil
        measured.nil? ? item : item.merge("value" => measured)
      end

      def default_risk(risk)
        caps = risk["caps"].is_a?(Hash) ? risk["caps"] : {}
        {
          "caps" => {
            "est_files" => caps["est_files"].to_i,
            "est_diff_lines" => caps["est_diff_lines"].to_i,
            "single_feature" => caps.key?("single_feature") ? caps["single_feature"] == true : true
          },
          "public_api_impact" => risk["public_api_impact"] == true,
          "public_api_details" => Array(risk["public_api_details"]),
          "cross_feature_impact" => risk["cross_feature_impact"] == true,
          "cross_feature_details" => Array(risk["cross_feature_details"]),
          "flags" => Array(risk["flags"])
        }
      end

      def enforce_behavior_guidance!(feature, hash)
        validation = hash.fetch("required_validation")
        known_commands = configured_commands.keys
        validation["commands"] = Array(validation["commands"]).map(&:to_s).select { |key| known_commands.include?(key) }
        has_tests = Array(feature.tests).any?

        # R8/A3: every admissible thesis must name validation commands OR opt
        # into characterization-first guidance. When the agent supplies
        # neither, inject the configured test command for test-rich slices and
        # fall back to characterization-first when no command is available.
        if validation["commands"].empty? && !validation["characterization_first"]
          if has_tests && known_commands.include?("test")
            validation["commands"] = [ "test" ]
          else
            validation["characterization_first"] = true
            validation["notes"] = if has_tests
              "Name explicit validation commands or characterize behavior before refactoring."
            else
              "Add characterization tests before refactoring this test-poor slice."
            end
          end
        end

        hash["confidence"] = "medium" if !has_tests && validation["characterization_first"] && hash["confidence"] == "high"
      end

      def enforce_admissibility!(hash)
        evidence = Array(hash["evidence"])
        has_file = evidence.any? { |item| item.is_a?(Hash) && !item["file"].to_s.strip.empty? }
        has_signal = evidence.any? do |item|
          item.is_a?(Hash) && MEASURABLE_SIGNALS.include?(item["signal"].to_s) && item.key?("value")
        end
        if has_file && has_signal
          hash["admissible"] = true
          hash["admissibility_reason"] = "evidence cites concrete paths and measurable signals"
          return
        end

        hash["admissible"] = false
        reasons = []
        reasons << "missing concrete file path" unless has_file
        reasons << "missing measurable signal" unless has_signal
        hash["admissibility_reason"] = reasons.join("; ")
        hash["risk"]["flags"] |= [ "inadmissible" ]

        # R7/R10/DoD flag-not-drop: a truly evidence-less thesis would fail the
        # schema's evidence.minItems and be dropped as schema_invalid (pinning
        # last_scanned_sha and forcing perpetual re-scan). Seed a synthetic
        # marker so it survives to the report as a flagged inadmissible record.
        if evidence.empty?
          hash["evidence"] = [ { "snippet" => "no evidence supplied; retained as inadmissible" } ]
        end
      end

      def schema_errors(hash)
        @schemer.validate(hash).map { |error| error.fetch("error", error.inspect) }
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

      def run_agent(prompt:, output_path:, run_dir:, **)
        task = Hive::Patrol::RunnerTask.new(
          folder: run_dir,
          project_root: @project_root,
          state_file: File.join(run_dir, "review.md"),
          # In dry-run mode the run_dir is a throwaway tmp dir; route agent
          # logs there too so a preview creates no durable artifacts under
          # .hive-state/refactor_patrol/.
          log_dir: @dry_run ? File.join(run_dir, "logs") : File.join(@state.root, "logs"),
          slug: "refactor-patrol-review"
        )
        profile = Hive::AgentProfiles.lookup(@cfg.dig("refactor_patrol", "agent") || "claude", cfg: @cfg)
        started_at = Time.now.utc
        result = Hive::Agent.new(
          task: task,
          prompt: prompt,
          add_dirs: [ @project_root ],
          cwd: @project_root,
          max_budget_usd: @cfg.dig("budget_usd", "patrol") || 100,
          timeout_sec: @cfg.dig("timeout_sec", "patrol") || 3600,
          log_label: "refactor-patrol-review",
          profile: profile,
          expected_output: output_path,
          status_mode: :output_file_exists
        ).run!
        record_usage(result, profile, "refactor-patrol-review", started_at)
        result
      end

      def record_usage(result, profile, stage, started_at)
        usage = result && result[:usage]
        return unless usage

        Hive::UsageDb.record!(
          agent: profile_name(profile),
          model: usage[:model] || result[:model],
          project_slug: File.basename(@project_root.to_s),
          task_slug: stage,
          stage: stage,
          started_at: started_at,
          ended_at: Time.now.utc.iso8601,
          input: usage[:input] || 0,
          output: usage[:output] || 0,
          cached: usage[:cached] || 0
        )
      rescue StandardError => e
        warn "[hive] usage record failed: #{e.message}"
      end

      def profile_name(profile)
        return profile.name.to_s if profile.respond_to?(:name)

        (@cfg.dig("refactor_patrol", "agent") || "claude").to_s
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
