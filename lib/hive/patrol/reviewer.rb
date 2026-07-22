require "json"
require "pathname"
require "securerandom"
require "hive/agent"
require "hive/agent_profiles"
require "hive/patrol/finding"
require "hive/patrol/fingerprint"
require "hive/patrol/runner_task"
require "hive/patrol/agent_launch"
require "hive/patrol/review_error_details"
require "hive/patrol/source_reader"
require "hive/patrol/state_store"
require "hive/patrol/token_budget"
require "hive/patrol/validator"
require "hive/stages/base"

module Hive
  module Patrol
    class Reviewer
      STAGE = "patrol-review".freeze
      MAX_OUTPUT_BYTES = 64 * 1024
      MAX_PROMPT_OWNED_FILES = 4
      MAX_PROMPT_SOURCE_BYTES = 32 * 1024
      VALID_CATEGORIES = %w[bug security performance documentation test-gap maintainability].freeze
      VALID_SEVERITIES = %w[critical high medium low].freeze
      VALID_CONFIDENCE = %w[high medium low].freeze
      VALID_SCOPES = %w[local feature cross_feature system].freeze
      PRODUCTION_CATEGORIES = %w[bug security performance].freeze
      REVIEW_ERROR_KINDS = %w[agent_failed malformed_json schema_invalid review_error].freeze
      REQUIRED_TEXT_FIELDS = %w[
        title description recommendation contract impact root_cause reproduction validation
      ].freeze
      DOCUMENTATION_EXTENSIONS = %w[.md .mdx .rst .adoc .asciidoc .txt].freeze
      OutputReadError = Class.new(StandardError)

      TemplateBindings = Struct.new(
        :project_root, :feature, :output_path, :max_findings, :user_supplied_tag,
        :validation_keys,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      # Features whose review failed this run (agent error, malformed or
      # schema-invalid JSON, or any other read/parse failure). A non-empty
      # list means the scan was partial; the caller must not advance last_scanned_sha as
      # if the commit reviewed cleanly (U5 fail-loud).
      attr_reader :review_errors

      def initialize(project_root, cfg:, state: StateStore.new(project_root), agent_runner: nil,
                     token_budget: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @agent_runner = agent_runner || method(:run_agent)
        @token_budget = token_budget || TokenBudget.new(@project_root, cfg: cfg)
        @review_errors = []
        @source_reader = Hive::Patrol::SourceReader.new(@project_root)
      end

      def call(features)
        features.flat_map { |feature| review_feature(feature) }
      end

      private

      # One feature's failure must never abort the whole scan: a flaky or
      # non-zero agent (Agent#run! sets status :error, or :timeout for a
      # timed-out run, rather than raising)
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
          return record_feature_error(
            feature, "agent_failed", agent_error_message(result),
            Hive::Patrol::ReviewErrorDetails.from_agent_result(result)
          )
        end

        parse_findings(feature, output_path, run_id: File.basename(run_dir).delete_prefix("review-"))
      rescue JSON::ParserError => e
        record_feature_error(feature, "malformed_json", e.message)
      rescue StandardError => e
        record_feature_error(feature, "review_error", "#{e.class}: #{e.message}")
      end

      def agent_failed?(result)
        result.is_a?(Hash) && %i[error timeout].include?(result[:status])
      end

      def agent_error_message(result)
        message = result.is_a?(Hash) ? result[:error_message].to_s : ""
        return "review agent timed out" if message.empty? && result.is_a?(Hash) && result[:status] == :timeout

        message
      end

      def record_feature_error(feature, kind, message, details = {})
        error = { "feature_id" => feature.id, "error" => kind, "message" => message }.merge(details)
        @review_errors << error
        @state.write_run_log("review-error-#{SecureRandom.hex(4)}", error)
        []
      end

      def render_prompt(feature, output_path)
        Hive::Stages::Base.render(
          "patrol_review_prompt.md.erb",
          TemplateBindings.new(
            project_root: @project_root,
            feature: bounded_prompt_feature(feature),
            output_path: output_path,
            max_findings: max_findings,
            validation_keys: configured_validation_keys,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      # Candidate scoring and evidence validation retain the complete mapped
      # feature. The model receives a bounded initial view so large components
      # cannot spend the per-agent allowance loading every context and test
      # file before the response that must write findings. A concrete defect
      # hypothesis may still use the prompt's one direct follow-up round.
      def bounded_prompt_feature(feature)
        feature.dup.tap do |bounded|
          bounded.owned_files = bounded_owned_files(feature.owned_files)
          bounded.context_files = []
          bounded.tests = []
        end
      end

      def bounded_owned_files(paths)
        remaining = MAX_PROMPT_SOURCE_BYTES
        selected = []
        Array(paths).each do |path|
          break if selected.size >= MAX_PROMPT_OWNED_FILES

          bytes = @source_reader.read_bytes(path, limit: remaining + 1).bytesize
          if selected.empty? || bytes <= remaining
            selected << path
            remaining = [ remaining - bytes, 0 ].max
          end
        end
        selected
      end

      def parse_findings(feature, output_path, run_id:)
        doc = JSON.parse(read_output(output_path))
        unless doc.is_a?(Hash) && doc.keys == [ "findings" ] && doc.fetch("findings").is_a?(Array)
          return record_feature_error(
            feature, "schema_invalid", "reviewer output must be an object containing only a findings array"
          )
        end

        findings = doc.fetch("findings").first(max_findings).map.with_index do |raw, idx|
          finding = normalize_finding(feature, raw, idx, run_id: run_id)
          unless finding
            return record_feature_error(
              feature, "schema_invalid", "finding #{idx + 1} does not satisfy the patrol finding contract"
            )
          end

          finding
        end
        findings
      end

      def read_output(output_path)
        flags = File::RDONLY | File::BINARY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)

        File.open(output_path, flags) do |file|
          raise OutputReadError, "reviewer output is not a regular file" unless file.stat.file?

          bytes = file.read(MAX_OUTPUT_BYTES + 1) || "".b
          if bytes.bytesize > MAX_OUTPUT_BYTES
            raise OutputReadError, "reviewer output exceeds #{MAX_OUTPUT_BYTES} bytes"
          end

          bytes
        end
      end

      def normalize_finding(feature, raw, idx, run_id:)
        return nil unless raw.is_a?(Hash)

        category = raw["category"].to_s
        severity = raw["severity"].to_s
        confidence = raw["confidence"].to_s
        scope = raw["scope"].to_s
        return nil unless VALID_CATEGORIES.include?(category)
        return nil unless VALID_SEVERITIES.include?(severity)
        return nil unless VALID_CONFIDENCE.include?(confidence)
        return nil unless VALID_SCOPES.include?(scope)
        return nil unless REQUIRED_TEXT_FIELDS.all? { |field| present_text?(raw[field]) }

        evidence = normalized_evidence(raw["evidence"])
        return nil unless evidence&.any?
        return nil if PRODUCTION_CATEGORIES.include?(category) && evidence.none? { |item| production_evidence?(item) }
        return nil unless slice_anchored?(feature, evidence)
        evidence = prioritize_slice_evidence(feature, evidence)
        validation_key = normalized_validation_key(raw["validation_key"])
        return nil if configured_validation_keys.any? && validation_key.nil?

        finding = Finding.new(
          id: "#{feature.id}-#{run_id}-#{idx + 1}",
          feature_id: feature.id,
          category: category,
          severity: severity,
          confidence: confidence,
          title: raw["title"],
          description: raw["description"],
          recommendation: raw["recommendation"],
          scope: scope,
          contract: raw["contract"],
          impact: raw["impact"],
          root_cause: raw["root_cause"],
          reproduction: raw["reproduction"],
          validation: raw["validation"],
          validation_key: validation_key,
          evidence: evidence
        )
        # Stamp the fingerprint before persisting so the durable
        # findings/*.json record links back to dedup/PR state. Without
        # this the finding is written before Commands::Patrol assigns the
        # fingerprint, and Finding#to_h.compact drops the nil key —
        # leaving the audit record unlinked. Commands::Patrol stamps with
        # `||=`, so the value computed here is reused, not overwritten.
        finding.fingerprint = Fingerprint.compute(finding, project_root: @project_root)
        finding
      end

      def present_text?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def normalized_validation_key(value)
        candidate = value.to_s.strip
        candidate = configured_validation_keys.first if candidate.empty? && configured_validation_keys.one?
        candidate if configured_validation_keys.include?(candidate)
      end

      def configured_validation_keys
        commands = @cfg.dig("patrol", "commands") || {}
        Validator::COMMAND_NAMES.select do |name|
          commands[name].is_a?(String) && !commands[name].strip.empty?
        end
      end

      def normalized_evidence(value)
        return unless value.is_a?(Array)

        evidence = value.map do |item|
          next unless item.is_a?(Hash)

          path = item["file"].to_s.tr("\\", "/")
          line = item["line"]
          snippet = item["snippet"]
          next if path.empty? || Pathname.new(path).absolute? || path.split("/").include?("..")
          next unless line.is_a?(Integer) && line.positive?
          next unless present_text?(snippet)

          snippet = snippet.strip
          source_line = @source_reader.read_utf8(path).lines[line - 1]
          next unless source_line&.include?(snippet)

          item.merge("file" => path, "line" => line, "snippet" => snippet)
        end
        return if evidence.any?(&:nil?)

        evidence
      end

      def production_evidence?(item)
        path = item.fetch("file").downcase
        parts = path.split("/")
        return false if (parts & %w[test tests spec specs __tests__ fixtures]).any?
        return false if File.basename(path).match?(/(?:_test|_spec|\.test|\.spec)\.[^.]+\z/)

        !DOCUMENTATION_EXTENSIONS.include?(File.extname(path))
      end

      def slice_anchored?(feature, evidence)
        owned = slice_owned_paths(feature)
        evidence.any? { |item| slice_anchor?(owned, item) }
      end

      def prioritize_slice_evidence(feature, evidence)
        owned = slice_owned_paths(feature)
        primary, supporting = evidence.partition { |item| slice_anchor?(owned, item) }
        primary + supporting
      end

      def slice_owned_paths(feature)
        (Array(feature.entrypoints) + Array(feature.owned_files)).map { |path| path.to_s.tr("\\", "/") }
      end

      def slice_anchor?(owned, item)
        role = item["role"].to_s
        owned.include?(item.fetch("file")) && (role.empty? || %w[trigger root_cause].include?(role))
      end

      def run_agent(prompt:, output_path:, run_dir:, **)
        task = RunnerTask.new(
          folder: run_dir,
          project_root: @project_root,
          state_file: File.join(run_dir, "review.md"),
          log_dir: File.join(@state.root, "logs"),
          slug: STAGE
        )
        profile = Hive::AgentProfiles.lookup(@cfg.dig("patrol", "agent") || "claude", cfg: @cfg)
        launch = Hive::Patrol::AgentLaunch.prepare(profile: profile, prompt: prompt, role: :review)
        unless @token_budget.acquire(stage: STAGE, minimum_tokens: launch.fetch(:minimum_tokens))
          exhaustion = @token_budget.resource_exhaustion if @token_budget.respond_to?(:resource_exhaustion)
          return {
            status: :error,
            error_message: @token_budget.exhaustion_message,
            resource_exhaustion: exhaustion
          }
        end
        started_at = Time.now.utc
        result = nil
        begin
          result = Hive::Agent.new(
            task: task,
            prompt: prompt,
            add_dirs: [ @project_root ],
            cwd: @project_root,
            max_budget_usd: @token_budget.max_budget_usd(
              @cfg.dig("budget_usd", "patrol") || 100, stage: STAGE
            ),
            max_tokens: @token_budget.max_tokens(stage: STAGE),
            max_turns: launch.fetch(:max_turns),
            timeout_sec: @cfg.dig("timeout_sec", "patrol") || 3600,
            log_label: STAGE,
            profile: profile,
            expected_output: output_path,
            status_mode: :output_file_exists,
            cli_flags: launch.fetch(:cli_flags)
          ).run!
        ensure
          @token_budget.record!(
            result: result, profile: profile, stage: STAGE, started_at: started_at
          )
        end
        result
      end

      def max_findings
        @cfg.dig("patrol", "max_findings_per_feature") || 3
      end
    end
  end
end
