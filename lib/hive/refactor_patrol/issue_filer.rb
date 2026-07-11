require "hive/gh"
require "hive/refactor_patrol/semantic_descriptor"
require "hive/refactor_patrol/semantic_family"
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
      ANALYSIS_GUARD_REASONS = %w[
        exceeds_max_files
        exceeds_max_diff_lines
        not_single_feature
        public_api_impact
        cross_feature_impact
        dependency_bump
        missing_docs_validation
      ].freeze
      DETERMINISTIC_NONFIXABLE_REASONS = %w[
        agent_control_plane_violation
        boundary_violation
        caps_exceeded
        closed_without_merge
        dependency_change
        fix_guardrail
        missing_validation
        public_contract_change
        public_contract_safety_unavailable
        secret_detected
        validation_changed_head
        validation_failed
        validation_mutated_worktree
      ].freeze
      STRATEGIC_REASONS = (ANALYSIS_GUARD_REASONS + DETERMINISTIC_NONFIXABLE_REASONS).freeze
      LEGACY_TITLE = /\Arefactor(?:[ -])?patrol\s*:/i
      LEGACY_COMPONENT = /^\s*(?:-\s*)?Feature\s+id:\s*`([^`\r\n]+)`\s*$/i
      LEGACY_THESIS = /^\s*(?:-\s*)?Thesis\s+id:\s*`([^`\r\n]+)`\s*$/i
      LEGACY_FINGERPRINT = /^\s*(?:-\s*)?Fingerprint:\s*`([a-f0-9]{64})`\s*$/i
      LEGACY_SECTIONS = %w[problem cost proposed_refactor evidence].freeze
      LEGACY_SECTION_NAMES = {
        "problem" => "problem",
        "cost" => "cost",
        "proposed refactor" => "proposed_refactor",
        "evidence" => "evidence"
      }.freeze
      LEGACY_STOP_SECTIONS = %w[
        advisories flags risk risk/caps validation_guidance
      ].freeze
      LEGACY_PROBLEM_BRIDGE = %w[
        mixed_responsibilities duplicated_policy scattered_contract
        parallel_implementations other
      ].freeze
      LEGACY_REFACTOR_BRIDGE = %w[
        extract_boundary consolidate_policy consolidate_contract
        move_responsibility other
      ].freeze

      def self.create_intent_payload(canonical_action_id:, repository:, family_id:,
                                     thesis_fingerprint:)
        {
          "operation" => "create_issue",
          "canonical_action_id" => canonical_action_id,
          "repository" => repository,
          "family_id" => family_id,
          "thesis_fingerprint" => thesis_fingerprint
        }
      end

      def initialize(project_root, cfg:, gh: Hive::Gh)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @gh = gh
      end

      def publish(thesis:, family_id:, canonical_action_id:, job_id:, source:, reasons: [],
                  record_intent:, creation_attempted: false,
                  publication_state: nil,
                  authorize_create: -> { true })
        request_sent = false
        publication = normalize_publication_state(publication_state, creation_attempted)
        return result("invalid_publication_state", false) unless valid_publication_state?(
          publication, thesis, family_id, canonical_action_id, source
        )
        attempted = publication.key?("issue_create_intent")
        return result("issue_disabled", true) unless issue_enabled? || attempted
        return result("quality_gate_failed", true) unless attempted || eligible?(thesis, reasons)
        return result("invalid_family", true) unless valid_family_id?(family_id)
        return result("invalid_action", true) unless valid_action_id?(canonical_action_id)

        action_id = canonical_action_id.to_s
        repository = source.fetch("repository")
        host = source_github_host!(source, repository)
        marker = marker_for(family_id, action_id)
        lookup = lookup_existing(repository, marker, host, thesis: thesis, source: source)
        return lookup if lookup.is_a?(Result)

        existing, match_kind = lookup
        unless existing.empty?
          canonical = existing.min_by { |issue| issue.fetch("number").to_i }
          return reconcile(canonical, existing, family_id, action_id, match_kind: match_kind)
        end
        if attempted
          return result(
            "remote_outcome_unknown", false,
            receipts: base_receipts(family_id, action_id).merge("creation_intent" => true)
          )
        end

        body = body_for(thesis, family_id, job_id, source, reasons, marker)
        return result("secret_detected", true) if Hive::SecretPatterns.scan(body).any?

        unless authorize_create.call.equal?(true)
          return result("authority_revoked", false, receipts: base_receipts(family_id, action_id))
        end

        intent_payload = self.class.create_intent_payload(
          canonical_action_id: action_id, repository: repository,
          family_id: family_id, thesis_fingerprint: thesis.fingerprint
        )
        intent_receipt = persist_publication(record_intent, intent_payload)
        unless intent_receipt == true
          error = intent_receipt.is_a?(Exception) ? {
            "error" => "#{intent_receipt.class}: #{intent_receipt.message}"
          } : { "intent_receipt" => "not_true" }
          return result(
            "intent_persist_failed", false,
            receipts: base_receipts(family_id, action_id).merge(error)
          )
        end
        unless authorize_create.call.equal?(true)
          return result("authority_revoked", false, receipts: base_receipts(family_id, action_id))
        end
        request_sent = true
        url = @gh.create_issue(
          repository: repository, host: host, title: title_for(thesis), body: body, cfg: @cfg
        )
        result(
          "issue_created", true, issue_url: url,
          receipts: base_receipts(family_id, action_id).merge(
            "creation_intent" => true, "issue_url" => url
          )
        )
      rescue Hive::GhError => e
        outcome = request_sent || attempted ? "remote_outcome_unknown" : "issue_reconcile_failed"
        result(
          outcome, false,
          receipts: base_receipts(family_id, canonical_action_id).merge("error" => e.message)
        )
      rescue KeyError, ArgumentError => e
        result("invalid_issue_input", true, receipts: { "error" => e.message })
      rescue StandardError => e
        outcome = request_sent || attempted ? "remote_outcome_unknown" : "intent_persist_failed"
        result(
          outcome, false,
          receipts: base_receipts(family_id, canonical_action_id).merge(
            "error" => "#{e.class}: #{e.message}"
          )
        )
      end

      private

      def normalize_publication_state(value, creation_attempted)
        state = value.nil? ? {} : value
        return nil unless state.is_a?(Hash)

        normalized = state.each_with_object({}) { |(key, payload), result| result[key.to_s] = payload }
        if normalized.empty? && creation_attempted
          normalized["issue_create_intent"] = { "legacy" => true }
        end
        normalized
      end

      def valid_publication_state?(state, thesis, family_id, action_id, source)
        return false unless state.is_a?(Hash) && (state.keys - [ "issue_create_intent" ]).empty?

        intent = state["issue_create_intent"]
        return true unless intent
        return true if intent == { "legacy" => true }

        intent == self.class.create_intent_payload(
          canonical_action_id: action_id.to_s,
          repository: source.fetch("repository"), family_id: family_id,
          thesis_fingerprint: thesis.fingerprint
        )
      rescue KeyError
        false
      end

      def persist_publication(callback, payload)
        if callback.respond_to?(:parameters) && callback.parameters.empty?
          callback.call
        else
          callback.call(phase: "issue_create_intent", payload: payload)
        end
      rescue StandardError => e
        e
      end

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

      def lookup_existing(repository, marker, host, thesis:, source:)
        issues = @gh.issues_for_repository(
          repository: repository, host: host, cfg: @cfg
        )
        unless issues.is_a?(Array) && issues.all? { |issue| valid_issue_record?(issue, repository, host) }
          return result("issue_reconcile_failed", false, receipts: { "error" => "malformed issue lookup" })
        end

        marked = issues.select do |issue|
          issue.fetch("body").to_s.lines.any? { |line| line.strip == marker }
        end
        return [ marked, "v2_marker" ] unless marked.empty?

        legacy = legacy_matches(issues, thesis: thesis, source: source)
        [ legacy, legacy.empty? ? nil : "legacy_semantic" ]
      rescue Hive::GhError => e
        result("issue_reconcile_failed", false, receipts: { "error" => e.message })
      rescue ArgumentError => e
        result("issue_reconcile_failed", false, receipts: { "error" => e.message })
      end

      def valid_issue_record?(issue, repository, host)
        return false unless issue.is_a?(Hash)
        return false unless issue["number"].is_a?(Integer) && issue["number"].positive?
        return false unless %w[OPEN CLOSED].include?(issue["state"].to_s.upcase)
        return false unless issue["title"].is_a?(String) && !issue["title"].strip.empty?
        return false unless issue.key?("body") && (issue["body"].nil? || issue["body"].is_a?(String))

        uri = URI.parse(issue["url"].to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/issues/([1-9]\d*)\z})
        uri.is_a?(URI::HTTP) && uri.host && match &&
          uri.host.casecmp?(host.to_s) &&
          match[1].casecmp?(repository.to_s) && match[2].to_i == issue["number"] &&
          uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      rescue URI::InvalidURIError
        false
      end

      def legacy_matches(issues, thesis:, source:)
        target = SemanticDescriptor.call(thesis: thesis, source: source)
        matches = issues.filter_map do |issue|
          descriptor = legacy_descriptor(issue, target: target, source: source)
          next unless descriptor && legacy_compatible?(target, descriptor)

          [ issue, descriptor ]
        end
        descriptors = matches.map(&:last)
        pairwise = descriptors.combination(2).all? do |left, right|
          legacy_compatible?(left, right)
        end
        unless pairwise
          numbers = matches.map { |issue, _descriptor| issue.fetch("number") }.sort
          raise ArgumentError, "ambiguous legacy issues #{numbers.inspect} match different semantic families"
        end

        matches.map(&:first)
      end

      def legacy_descriptor(issue, target:, source:)
        title = issue.fetch("title")
        return unless title.match?(LEGACY_TITLE)

        body = issue.fetch("body")
        if !body.is_a?(String) || !body.valid_encoding? || body.bytesize > MAX_BODY_BYTES
          return unless title.downcase.include?(target.fetch("component"))

          raise ArgumentError, "legacy issue ##{issue.fetch('number')} has an invalid body"
        end
        return if body.include?("<!-- hive-refactor-patrol")

        components = body.scan(LEGACY_COMPONENT).flatten
        if components.size != 1
          return unless title.downcase.include?(target.fetch("component"))

          raise ArgumentError, "legacy issue ##{issue.fetch('number')} has ambiguous feature identity"
        end
        component = normalized_legacy_component(components.first, target)
        return unless component == target.fetch("component")

        validate_legacy_identity!(body, issue.fetch("number"))
        sections = legacy_sections(body, issue.fetch("number"))
        evidence = legacy_evidence(sections.fetch("evidence"), issue.fetch("number"))
        SemanticDescriptor.call(
          thesis: {
            "feature_id" => components.first,
            "feature" => components.first,
            "problem" => sections.fetch("problem"),
            "cost" => sections.fetch("cost"),
            "proposed_refactor" => sections.fetch("proposed_refactor"),
            "evidence" => evidence,
            "feature_boundary" => {
              "owned_files" => evidence.map { |entry| entry.fetch("file") },
              "entrypoints" => []
            },
            "expected_leverage" => {}
          },
          source: source
        )
      end

      def normalized_legacy_component(value, target)
        SemanticFamily.descriptor(
          host: target.fetch("host"), repository: target.fetch("repository"),
          component: value, problem_kind: "other", refactor_kind: "other",
          anchors: [ "legacy-identity" ], concepts: [ "legacy" ]
        ).fetch("component")
      end

      def validate_legacy_identity!(body, number)
        theses = body.scan(LEGACY_THESIS).flatten
        fingerprints = body.scan(LEGACY_FINGERPRINT).flatten
        return if theses.size == 1 && !theses.first.strip.empty? && fingerprints.size == 1

        raise ArgumentError, "legacy issue ##{number} has invalid thesis or fingerprint identity"
      end

      def legacy_sections(body, number)
        sections = {}
        current = nil
        body.each_line do |line|
          heading = legacy_heading_name(line)
          key = LEGACY_SECTION_NAMES[heading]
          if key
            raise ArgumentError, "legacy issue ##{number} repeats its #{key} section" if sections.key?(key)

            sections[key] = +""
            current = key
          elsif legacy_stop_section?(line, heading)
            current = nil
          elsif current
            sections.fetch(current) << line
          end
        end
        missing = LEGACY_SECTIONS.reject do |key|
          sections.key?(key) && !sections.fetch(key).strip.empty?
        end
        unless missing.empty?
          raise ArgumentError, "legacy issue ##{number} is missing sections #{missing.inspect}"
        end

        sections.transform_values(&:strip)
      end

      def legacy_stop_section?(line, heading)
        stripped = line.strip
        return false if stripped.empty?

        LEGACY_STOP_SECTIONS.include?(heading.tr(" ", "_")) || stripped.match?(/\A[#]{1,6}\s+/)
      end

      def legacy_heading_name(line)
        line.to_s.strip.sub(/\A[#]{1,6}\s+/, "").delete_suffix(":").strip.downcase
      end

      def legacy_evidence(text, number)
        evidence = text.lines.filter_map do |line|
          match = line.chomp.match(/\A\s*-\s+`([^`\r\n]+):([1-9]\d*)`\s*(.*)\z/)
          next unless match

          {
            "file" => match[1].strip,
            "line" => match[2].to_i,
            "claim" => match[3].to_s.strip
          }
        end
        return evidence unless evidence.empty?

        raise ArgumentError, "legacy issue ##{number} has no anchored evidence"
      end

      def legacy_compatible?(left, right)
        return true if SemanticFamily.compatible?(left, right)
        return false unless legacy_kind_compatible?(
          left.fetch("problem_kind"), right.fetch("problem_kind"), LEGACY_PROBLEM_BRIDGE
        )
        return false unless legacy_kind_compatible?(
          left.fetch("refactor_kind"), right.fetch("refactor_kind"), LEGACY_REFACTOR_BRIDGE
        )

        SemanticFamily.compatible?(
          left.merge("problem_kind" => "other", "refactor_kind" => "other"),
          right.merge("problem_kind" => "other", "refactor_kind" => "other")
        )
      end

      def legacy_kind_compatible?(left, right, bridge)
        left == right || (bridge.include?(left) && bridge.include?(right))
      end

      def source_github_host!(source, repository)
        uri = URI.parse(source.fetch("url").to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        valid = uri.is_a?(URI::HTTP) && uri.host && match &&
                match[1].casecmp?(repository.to_s) && uri.userinfo.nil? &&
                uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, "source PR URL does not match its GitHub repository" unless valid

        uri.host
      rescue URI::InvalidURIError
        raise ArgumentError, "source PR URL is invalid"
      end

      def reconcile(canonical, issues, family_id, action_id, match_kind:)
        url = canonical.fetch("url").to_s
        state = canonical.fetch("state").to_s.upcase
        outcome = state == "OPEN" ? "issue_linked_open" : "issue_closed_suppressed"
        result(
          outcome, true, issue_url: url,
          receipts: base_receipts(family_id, action_id).merge(
            "issue_url" => url,
            "issue_number" => canonical.fetch("number").to_i,
            "match_kind" => match_kind,
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
