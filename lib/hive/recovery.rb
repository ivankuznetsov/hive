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
        utf8.valid_encoding? ? utf8 : value.b
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

    # A max-pass REVIEW_STALE with unresolved reviewer input needs an operator
    # edit. A newer fix-success receipt proves the escalations were already
    # handled; that shape is restart recovery, not a human decision, and may
    # use the ordinary automatic retry path.
    def intervention_required?(marker:, attrs:, folder:)
      review_stale_recovery_state(marker:, attrs:, folder:) == :operator
    end

    def completed_review_stale?(marker:, attrs:, folder:)
      review_stale_recovery_state(marker:, attrs:, folder:) == :automatic
    end

    def review_stale_recovery_state(marker:, attrs:, folder:)
      return :not_applicable unless marker.to_s.downcase == "review_stale"

      normalized = attrs.to_h.transform_keys(&:to_s)
      pass = normalized["pass"].to_s
      return :not_applicable unless pass.match?(/\A[1-9]\d*\z/)

      suffix = format("%02d", pass.to_i)
      escalations = File.join(folder.to_s, "reviews", "escalations-#{suffix}.md")
      return :not_applicable unless File.exist?(escalations)

      fix_success = File.join(folder.to_s, "reviews", "fix-success-#{suffix}.md")
      return :operator unless File.exist?(fix_success)

      File.mtime(fix_success) < File.mtime(escalations) ? :operator : :automatic
    rescue SystemCallError, IOError
      :operator
    end
  end
end
