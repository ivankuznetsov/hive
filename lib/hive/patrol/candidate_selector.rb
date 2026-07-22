require "set"
require "hive/patrol/fingerprint"
require "hive/patrol/validator"

module Hive
  module Patrol
    class CandidateSelector
      AUTO_FIX_CATEGORIES = %w[bug security performance].freeze
      FIXABLE_SEVERITIES = %w[critical high medium].freeze
      DEFAULT_MIN_ALPHA = 70
      DEFAULT_FEATURE_LIMIT = 1
      SKIP_REASONS = %w[
        dismissed existing_pr similar_to_existing low_confidence low_severity
        non_production invalid_validation low_alpha active_feature
        duplicate_in_run feature_limit semantic_duplicate
      ].freeze
      # The corpus showed model-authored severity/confidence labels did not
      # predict whether a finding delivered. Treat them as admission gates and
      # tiny tie-breakers; most alpha comes from satisfying the complete defect
      # contract, verified evidence breadth, category, novelty, and scope.
      #
      # Maximum attainable alpha is 87 (3 severity + 2 confidence + 8 category
      # + 6 scope + 60 structured proof + 8 evidence breadth, with no history
      # penalty), so min_alpha_to_fix values of 88-100 disable fixing entirely
      # even though config validation accepts up to 100.
      STRUCTURED_PROOF_POINTS = 60
      MAX_HISTORY_PENALTY = 24
      REQUIRED_PROOF_FIELDS = %i[contract impact root_cause reproduction validation].freeze

      SEVERITY_POINTS = {
        "critical" => 3,
        "high" => 2,
        "medium" => 2,
        "low" => 0
      }.freeze
      CONFIDENCE_POINTS = {
        "high" => 2,
        "medium" => 2,
        "low" => 0
      }.freeze
      CATEGORY_POINTS = {
        "security" => 8,
        "bug" => 7,
        "performance" => 6
      }.freeze
      SCOPE_POINTS = {
        "local" => 2,
        "feature" => 4,
        "cross_feature" => 6,
        "system" => 6
      }.freeze

      def initialize(cfg:, fingerprints:, dismissed:)
        cfg = {} unless cfg.is_a?(Hash)
        @cfg = cfg["patrol"] || cfg[:patrol] || {}
        @fingerprints = fingerprints.is_a?(Hash) ? fingerprints : {}
        @dismissed = dismissed.is_a?(Hash) ? dismissed : {}
        @similarity_index = Fingerprint.similarity_index(@fingerprints, @dismissed)
        @active_features, @dismissed_features = index_history
      end

      def call(findings)
        skipped = []
        scored = Array(findings).filter_map do |finding|
          reason = base_skip_reason(finding)
          if reason
            skipped << skip_entry(finding, reason)
            next
          end

          finding.alpha_score = score(finding)
          if finding.alpha_score < min_alpha
            skipped << skip_entry(finding, "low_alpha")
            next
          end
          finding
        end

        select_ranked(scored, skipped)
      end

      private

      def base_skip_reason(finding)
        return "non_production" unless AUTO_FIX_CATEGORIES.include?(finding.category.to_s)
        return "dismissed" if Fingerprint.dismissed?(@dismissed, finding.fingerprint)
        return "existing_pr" if Fingerprint.known_active?(@fingerprints, finding.fingerprint)
        if Fingerprint.similar_known?(@fingerprints, @dismissed, finding, index: @similarity_index)
          return "similar_to_existing"
        end
        return "low_confidence" unless Fingerprint.fixable_confidence?(finding, config_value("min_confidence_to_fix", "medium"))
        return "low_severity" unless FIXABLE_SEVERITIES.include?(finding.severity.to_s)
        return "invalid_validation" unless valid_validation_key?(finding)
        return "active_feature" if active_feature?(finding)

        nil
      end

      def valid_validation_key?(finding)
        commands = @cfg["commands"] || @cfg[:commands] || {}
        configured = Validator::COMMAND_NAMES.select do |name|
          value = commands[name] || commands[name.to_sym]
          value.is_a?(String) && !value.strip.empty?
        end
        return true if configured.empty?

        configured.include?(finding.validation_key.to_s)
      end

      def select_ranked(scored, skipped)
        selected = []
        feature_counts = Hash.new(0)
        sorted_findings(scored).each do |finding|
          reason =
            if duplicate_in_run?(finding, selected)
              "duplicate_in_run"
            elsif feature_counts[finding.feature_id.to_s] >= feature_limit
              "feature_limit"
            end
          if reason
            skipped << skip_entry(finding, reason)
            next
          end

          selected << finding
          feature_counts[finding.feature_id.to_s] += 1
        end
        [ selected, skipped ]
      end

      def sorted_findings(findings)
        findings.sort_by do |finding|
          [ -finding.alpha_score, finding.feature_id.to_s, finding.id.to_s, finding.fingerprint.to_s ]
        end
      end

      def score(finding)
        total = SEVERITY_POINTS.fetch(finding.severity.to_s, 0)
        total += CONFIDENCE_POINTS.fetch(finding.confidence.to_s, 0)
        total += CATEGORY_POINTS.fetch(finding.category.to_s, 0)
        total += SCOPE_POINTS.fetch(finding.scope.to_s, 0)
        total += structured_proof_points(finding)
        total += evidence_points(finding.evidence)
        total -= history_penalty(finding)
        total.clamp(0, 100)
      end

      def evidence_points(evidence)
        breadth_points(evidence_paths(evidence).uniq.length)
      end

      def structured_proof_points(finding)
        complete = REQUIRED_PROOF_FIELDS.all? do |field|
          finding.respond_to?(field) && !finding.public_send(field).to_s.strip.empty?
        end
        complete ? STRUCTURED_PROOF_POINTS : 0
      end

      def breadth_points(count)
        case count.to_i
        when 0 then 0
        when 1 then 2
        when 2 then 5
        else 8
        end
      end

      def history_penalty(finding)
        dismissed = @dismissed_features.each_with_object(Set.new) do |(feature_id, fingerprints), matching|
          matching.merge(fingerprints) if Fingerprint.same_feature_history?(feature_id, finding)
        end
        [ dismissed.length * 12, MAX_HISTORY_PENALTY ].min
      end

      def active_feature?(finding)
        @active_features.any? { |feature_id| Fingerprint.same_feature_history?(feature_id, finding) }
      end

      def index_history
        active = Set.new
        dismissed_keys = Hash.new { |hash, feature_id| hash[feature_id] = Set.new }

        @fingerprints.each do |fingerprint, entry|
          feature_id = entry_feature_id(entry)
          next unless feature_id

          case entry_state(entry)
          when "open" then active << feature_id
          when "dismissed" then dismissed_keys[feature_id] << fingerprint
          end
        end
        @dismissed.each do |fingerprint, entry|
          feature_id = entry_feature_id(entry)
          dismissed_keys[feature_id] << fingerprint if feature_id
        end

        dismissed_keys.each_value(&:freeze)
        [ active.freeze, dismissed_keys.freeze ]
      end

      def entry_state(entry)
        return "" unless entry.is_a?(Hash)

        (entry["state"] || entry[:state]).to_s
      end

      def entry_feature_id(entry)
        return nil unless entry.is_a?(Hash)

        explicit = entry["feature_id"] || entry[:feature_id]
        return explicit.to_s unless explicit.to_s.empty?

        branch = (entry["branch"] || entry[:branch]).to_s
        branch[%r{\Ahive-patrol/(.+)-[0-9a-fA-F]{8}\z}, 1]
      end

      def duplicate_in_run?(finding, selected)
        selected.any? do |other|
          next false unless other.category.to_s == finding.category.to_s

          overlap = semantic_overlap_score(finding, other)
          overlap >= Fingerprint::SIMILARITY_THRESHOLD ||
            (same_primary_path?(finding, other) && overlap >= 0.35)
        end
      end

      def same_primary_path?(left, right)
        left_path = evidence_paths(left.evidence).first
        right_path = evidence_paths(right.evidence).first
        !left_path.to_s.empty? && left_path == right_path
      end

      def semantic_overlap_score(left, right)
        left_tokens = Fingerprint.semantic_tokens(left)
        right_tokens = Fingerprint.semantic_tokens(right)
        return 0.0 if left_tokens.empty? || right_tokens.empty?

        Fingerprint.overlap_coefficient(left_tokens, right_tokens)
      end

      def evidence_paths(evidence)
        Array(evidence).filter_map do |item|
          next unless item.is_a?(Hash)

          path = Fingerprint.normalized_path(item["file"] || item[:file])
          path unless path.empty?
        end
      end

      def min_alpha
        integer_config("min_alpha_to_fix", DEFAULT_MIN_ALPHA).clamp(0, 100)
      end

      def feature_limit
        [ integer_config("max_fixes_per_feature_per_cycle", DEFAULT_FEATURE_LIMIT), 1 ].max
      end

      def integer_config(key, default)
        Integer(config_value(key, default), exception: false) || default
      end

      def config_value(key, default)
        @cfg.fetch(key) { @cfg.fetch(key.to_sym, default) }
      end

      def skip_entry(finding, reason)
        {
          "finding_id" => finding.id,
          "fingerprint" => finding.fingerprint,
          "reason" => reason
        }
      end
    end
  end
end
