require "hive/review_escalations"

module Hive
  # Shared, policy-free vocabulary for durable recovery. Mutation and pacing
  # remain owned by RecoveryCoordinator; adapters use Recovery::API.
  module Recovery
    RECOVERABLE_MARKERS = %w[
      error review_error review_stale review_ci_stale
    ].freeze
    OWNERS = %w[agent operator provider scheduler hive none unknown].freeze

    module_function

    def recoverable_marker?(marker)
      RECOVERABLE_MARKERS.include?(marker.to_s.downcase)
    end

    # Marker reads intentionally use a binary view so invalid agent-authored
    # artifacts cannot prevent Hive from finding a trailing ASCII marker.
    # Durable requests and daemon snapshots pass through JSON, which restores
    # valid text as UTF-8. Canonicalize valid UTF-8 bytes at that wire boundary
    # so an encoding label alone cannot manufacture a generation conflict;
    # preserve genuinely invalid bytes as binary so JSON still fails closed.
    def canonical_wire_value(value)
      case value
      when Hash
        originals = value.each_key.with_object({}) do |candidate, out|
          key = candidate.to_s
          out[key] = candidate if !out.key?(key) || candidate.is_a?(String)
        end
        originals.keys.sort.to_h do |key|
          original = originals.fetch(key)
          [ key, canonical_wire_value(value.fetch(original)) ]
        end
      when Array
        value.map { |entry| canonical_wire_value(entry) }
      when String
        utf8 = value.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8.unicode_normalize(:nfc) : value.b
      else
        value
      end
    end

    def canonical_marker_attrs(attrs)
      canonical_wire_value(attrs.to_h.transform_keys(&:to_s))
    end

    def marker_attrs_match?(actual, expected)
      actual = canonical_marker_attrs(actual)
      canonical_marker_attrs(expected).all? do |key, expected_value|
        canonical_wire_value(actual[key].to_s) ==
          canonical_wire_value(expected_value.to_s)
      end
    end

    RETRY_STEP = "refresh `hive status --operational --json` and invoke this " \
                 "task's workflow.retry action with `hive act`".freeze

    # A max-pass REVIEW_STALE with unresolved reviewer input needs an operator
    # edit; no surface may offer a routine retry for it. Once the operator has
    # answered an escalation (:operator_answered), operator surfaces may submit
    # the guarded retry, but the daemon still never retries it on its own.
    def intervention_required?(marker:, attrs:, folder:)
      review_stale_recovery_state(marker:, attrs:, folder:) == :operator
    end

    # True for every max-pass REVIEW_STALE that only an operator may resume,
    # answered or not. Automatic recovery (healer/daemon) checks this.
    def operator_owned_review_stale?(marker:, attrs:, folder:)
      %i[operator operator_answered].include?(
        review_stale_recovery_state(marker:, attrs:, folder:)
      )
    end

    # A newer fix-success receipt proves the escalations were already handled;
    # that shape is restart recovery, not a human decision, and may use the
    # ordinary automatic retry path.
    def completed_review_stale?(marker:, attrs:, folder:)
      review_stale_recovery_state(marker:, attrs:, folder:) == :automatic
    end

    # :not_applicable — not a pass-bound REVIEW_STALE with escalations.
    # :automatic — fresh fix-success receipt; restart recovery.
    # :operator — operator input is still missing.
    # :operator_answered — the operator answered at least one escalation for
    #   the marker's pass; explicit operator retry only.
    def review_stale_recovery_state(marker:, attrs:, folder:)
      return :not_applicable unless marker.to_s.downcase == "review_stale"

      normalized = attrs.to_h.transform_keys(&:to_s)
      final_fix = normalized["reason"] == "final_fix_unverified"
      pass = normalized["pass"].to_s
      unless pass.match?(/\A[1-9]\d*\z/)
        return final_fix ? :operator : :not_applicable
      end

      escalations = Hive::ReviewEscalations.path(folder, pass)
      unless File.exist?(escalations)
        return final_fix ? :operator : :not_applicable
      end

      unless final_fix
        fix_success = File.join(folder.to_s, "reviews", "fix-success-#{format('%02d', pass.to_i)}.md")
        if File.exist?(fix_success) && File.mtime(fix_success) >= File.mtime(escalations)
          return :automatic
        end
      end

      operator_answered?(escalations, normalized) ? :operator_answered : :operator
    rescue SystemCallError, IOError, EncodingError, ArgumentError
      :operator
    end

    # The next fix pass consumes every non-empty `### A<n>.` answer and skips
    # blank ones, and a verify pass hands the whole file to triage, so one
    # answer is real input. When the marker recorded how many questions were
    # open at stall time (`escalations=`), answers already present then do not
    # count: only an answer added afterwards is new operator input.
    def operator_answered?(escalations, attrs)
      questions = Hive::ReviewEscalations.questions(escalations)
      answered = questions.count { |question| Hive::ReviewEscalations.answered?(question) }
      return false if answered.zero?

      recorded = attrs["escalations"].to_s
      return true unless recorded.match?(/\A\d+\z/)

      questions.length - answered < recorded.to_i
    end

    # Operator-facing next step for a REVIEW_STALE marker, shared by the stage
    # runner's pre-flight warning and `hive run`/`hive review` reports.
    def review_stale_guidance(attrs:, folder:)
      normalized = attrs.to_h.transform_keys(&:to_s)
      state = review_stale_recovery_state(marker: "review_stale", attrs: normalized, folder: folder)
      return "inspect or edit the highest-pass review files, then #{RETRY_STEP}" unless
        %i[operator operator_answered].include?(state)

      escalations = Hive::ReviewEscalations.path(folder, normalized["pass"])
      file = "reviews/#{File.basename(escalations)}"
      if state == :operator_answered
        return "operator answers in #{file} are recorded; #{RETRY_STEP} " \
               "(Hive never retries this automatically)"
      end

      final_fix = normalized["reason"] == "final_fix_unverified"
      grant = "grant more fix passes with the review_grant action in `hive status --operational --json`"
      open = Hive::ReviewEscalations.questions(escalations)
        .any? { |question| !Hive::ReviewEscalations.answered?(question) }
      if open
        step = "answer the open `### A<n>.` questions in #{file}, then #{RETRY_STEP}"
        return final_fix ? "#{step}; to let Hive apply fixes instead, #{grant} before answering" : step
      end
      if final_fix
        return "no escalation question is open; #{grant}, or commit fixes locally " \
               "and retry from `hive tui` with `r`"
      end

      "edit #{file}, then retry from `hive tui` with `r`"
    rescue SystemCallError, IOError, EncodingError, ArgumentError
      "inspect or edit the highest-pass review files, then #{RETRY_STEP}"
    end
  end
end
