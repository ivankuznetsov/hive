require "hive/gh"
require "hive/secret_patterns"
require "uri"

module Hive
  module RefactorPatrol
    # Publishes one quality-gated strategic finding per semantic family.
    # Durable callers must persist +record_intent+ before the remote create;
    # after an ambiguous response this class only reconciles and never retries
    # creation automatically.
    class IssueFiler
      Result = Struct.new(:outcome, :terminal, :issue_url, :receipts, keyword_init: true)

      MAX_TITLE = 200
      MAX_BODY_BYTES = 20_000
      CONFIDENCE_ORDER = { "low" => 0, "medium" => 1, "high" => 2 }.freeze
      STRATEGIC_REASONS = %w[
        exceeds_max_files
        exceeds_max_diff_lines
        not_single_feature
        public_api_impact
        cross_feature_impact
        dependency_bump
        caps_exceeded
        dependency_change
        public_contract_change
      ].freeze

      def initialize(project_root, cfg:, gh: Hive::Gh)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @gh = gh
      end

      def publish(thesis:, family_id:, canonical_action_id:, job_id:, source:, reasons: [],
                  record_intent:, creation_attempted: false)
        return result("issue_disabled", true) unless issue_enabled? || creation_attempted
        return result("quality_gate_failed", true) unless creation_attempted || eligible?(thesis, reasons)
        return result("invalid_family", true) unless valid_family_id?(family_id)
        return result("invalid_action", true) unless valid_action_id?(canonical_action_id)

        action_id = canonical_action_id.to_s
        marker = marker_for(family_id, action_id)
        existing = lookup_existing(source.fetch("repository"), marker)
        return existing if existing.is_a?(Result)
        unless existing.empty?
          canonical = existing.min_by { |issue| issue.fetch("number").to_i }
          return reconcile(canonical, existing, family_id, action_id)
        end
        if creation_attempted
          return result(
            "remote_outcome_unknown", false,
            receipts: base_receipts(family_id, action_id).merge("creation_intent" => true)
          )
        end

        body = body_for(thesis, family_id, job_id, source, reasons, marker)
        return result("secret_detected", true) if Hive::SecretPatterns.scan(body).any?

        intent_receipt = record_intent.call
        unless intent_receipt.equal?(true)
          return result(
            "intent_persist_failed", false,
            receipts: base_receipts(family_id, action_id).merge("intent_receipt" => "not_true")
          )
        end
        intent_persisted = true
        url = @gh.create_issue(
          repository: source.fetch("repository"), title: title_for(thesis),
          body: body, cfg: @cfg
        )
        result(
          "issue_created", true, issue_url: url,
          receipts: base_receipts(family_id, action_id).merge(
            "creation_intent" => true, "issue_url" => url
          )
        )
      rescue Hive::GhError => e
        outcome = intent_persisted || creation_attempted ? "remote_outcome_unknown" : "issue_reconcile_failed"
        result(
          outcome, false,
          receipts: base_receipts(family_id, canonical_action_id).merge("error" => e.message)
        )
      rescue KeyError, ArgumentError => e
        result("invalid_issue_input", true, receipts: { "error" => e.message })
      rescue StandardError => e
        # A local receipt failure must happen before the remote call. Keep it
        # retryable, but do not turn it into an ambiguous remote outcome.
        result(
          "intent_persist_failed", false,
          receipts: base_receipts(family_id, canonical_action_id).merge(
            "error" => "#{e.class}: #{e.message}"
          )
        )
      end

      private

      def issue_enabled?
        @cfg.dig("refactor_patrol", "issue_filing", "enabled") == true
      end

      def eligible?(thesis, reasons)
        return false unless thesis.admissible == true
        return false if confidence(thesis.confidence) < minimum_confidence
        return false if thesis.expected_leverage.to_h.fetch("score", 0).to_f < minimum_leverage_score

        flags = Array(thesis.risk && thesis.risk["flags"]).map(&:to_s)
        strategic = (flags + Array(reasons).map(&:to_s)) & STRATEGIC_REASONS
        !strategic.empty?
      end

      def confidence(value)
        CONFIDENCE_ORDER.fetch(value.to_s, -1)
      end

      def minimum_confidence
        confidence(@cfg.dig("refactor_patrol", "min_confidence") || "medium")
      end

      def minimum_leverage_score
        @cfg.dig("refactor_patrol", "issue_filing", "min_leverage_score").to_f
      end

      def valid_family_id?(family_id)
        family_id.to_s.match?(/\Aaf1-[a-f0-9]{64}\z/)
      end

      def valid_action_id?(action_id)
        action_id.to_s.match?(/\Aissue-[a-f0-9]{64}\z/)
      end

      def lookup_existing(repository, marker)
        issues = @gh.issues_with_marker(repository: repository, marker: marker, cfg: @cfg)
        unless issues.is_a?(Array) && issues.all? { |issue| valid_issue_record?(issue, repository) }
          return result("issue_reconcile_failed", false, receipts: { "error" => "malformed issue lookup" })
        end

        issues
      rescue Hive::GhError => e
        result("issue_reconcile_failed", false, receipts: { "error" => e.message })
      end

      def valid_issue_record?(issue, repository)
        return false unless issue.is_a?(Hash)
        return false unless issue["number"].is_a?(Integer) && issue["number"].positive?
        return false unless %w[OPEN CLOSED].include?(issue["state"].to_s.upcase)

        uri = URI.parse(issue["url"].to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/issues/([1-9]\d*)\z})
        uri.is_a?(URI::HTTP) && uri.host && match &&
          match[1].casecmp?(repository.to_s) && match[2].to_i == issue["number"] &&
          uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      rescue URI::InvalidURIError
        false
      end

      def reconcile(canonical, issues, family_id, action_id)
        url = canonical.fetch("url").to_s
        state = canonical.fetch("state").to_s.upcase
        outcome = state == "OPEN" ? "issue_linked_open" : "issue_closed_suppressed"
        result(
          outcome, true, issue_url: url,
          receipts: base_receipts(family_id, action_id).merge(
            "issue_url" => url,
            "issue_number" => canonical.fetch("number").to_i,
            "duplicate_issue_urls" => issues.reject { |issue| issue.equal?(canonical) }
                                             .map { |issue| issue.fetch("url").to_s }.sort
          )
        )
      end

      def body_for(thesis, family_id, job_id, source, reasons, marker)
        flags = (Array(thesis.risk && thesis.risk["flags"]) + Array(reasons)).map(&:to_s).uniq.sort
        content = <<~MD
          ## Architecture patrol finding

          Source PR: #{source.fetch("url")}
          Job: `#{job_id}`
          Thesis: `#{thesis.id}`
          Semantic family: `#{family_id}`
          Occurrence fingerprint: `#{thesis.fingerprint}`

          ### Problem and cost

          #{thesis.problem}

          #{thesis.cost}

          ### Evidence

          #{evidence_lines(thesis.evidence)}

          ### Proposed refactor

          #{thesis.proposed_refactor}

          ### Expected leverage

          #{leverage_lines(thesis.expected_leverage)}

          ### Strategic reasons

          #{flags.map { |flag| "- #{flag}" }.join("\n")}

          ### Required validation

          #{validation_lines(thesis.required_validation)}
        MD
        append_marker(content, marker)
      end

      def append_marker(content, marker)
        suffix = "\n\n#{marker}\n"
        available = MAX_BODY_BYTES - suffix.bytesize
        prefix = content.to_s.b.byteslice(0, [ available, 0 ].max).to_s
        "#{prefix.force_encoding(Encoding::UTF_8).scrub("")}#{suffix}"
      end

      def evidence_lines(evidence)
        Array(evidence).map do |item|
          next "- unstructured evidence" unless item.is_a?(Hash)

          location = [ item["file"], item["line"] ].compact.join(":")
          claim = item["claim"].to_s.strip
          snippet = item["snippet"].to_s.strip
          details = [ claim, snippet ].reject(&:empty?).join(" — ")
          [ "- `#{location}`", details ].reject(&:empty?).join(": ")
        end.join("\n")
      end

      def validation_lines(validation)
        validation ||= {}
        commands = Array(validation["commands"])
        lines = commands.map { |command| "- command: #{command}" }
        lines << "- characterization first: #{validation['notes']}" if validation["characterization_first"] == true
        lines << "- notes: #{validation['notes']}" if lines.empty? && !validation["notes"].to_s.empty?
        lines.empty? ? "- no validation supplied" : lines.join("\n")
      end

      def leverage_lines(leverage)
        leverage ||= {}
        lines = [ "Expected leverage score: #{leverage.fetch('score', 0).to_f.round(3)}" ]
        Array(leverage["drivers"]).each do |driver|
          next unless driver.is_a?(Hash)

          lines << "- #{driver['signal']}: relief #{driver['relief']} — #{driver['mechanism']}"
        end
        lines.join("\n")
      end

      def title_for(thesis)
        "Architecture patrol: #{thesis.problem.to_s.lines.first.to_s.strip}"[0, MAX_TITLE]
      end

      def marker_for(family_id, action_id)
        "<!-- hive-refactor-patrol family=#{family_id} action=#{action_id} -->"
      end

      def base_receipts(family_id, action_id)
        { "family_id" => family_id.to_s, "canonical_action_id" => action_id.to_s }
      end

      def result(outcome, terminal, issue_url: nil, receipts: {})
        Result.new(
          outcome: outcome, terminal: terminal, issue_url: issue_url,
          receipts: receipts
        )
      end
    end
  end
end
