require "digest"
require "set"

module Hive
  module RefactorPatrol
    module Fingerprint
      SIMILARITY_THRESHOLD = 0.6

      module_function

      def compute(thesis, project_root:)
        evidence = Array(thesis.evidence).first || {}
        path = normalized_path(evidence["file"] || evidence[:file])
        payload = [
          thesis.feature_id.to_s,
          path,
          normalize_token(thesis.problem),
          normalize_token(thesis.proposed_refactor)
        ].join("\0")
        ::Digest::SHA256.hexdigest(payload)
      end

      def known_active?(fingerprints, fingerprint)
        state = fingerprints.dig(fingerprint, "state")
        %w[seen open pending approved].include?(state)
      end

      def dismissed?(dismissed, fingerprint)
        dismissed.key?(fingerprint)
      end

      def similar_known?(fingerprints, dismissed, thesis)
        tokens = title_tokens(thesis)
        return false if tokens.empty?

        feature_id = thesis.feature_id.to_s
        active = fingerprints.values.select { |entry| %w[seen open pending approved].include?(entry["state"]) }
        (active + dismissed.values).any? do |entry|
          next false unless entry["feature_id"].to_s == feature_id

          other = Array(entry["title_tokens"]).map(&:to_s)
          next false if other.empty?

          overlap_coefficient(tokens, other) >= SIMILARITY_THRESHOLD
        end
      end

      def record_seen(fingerprints, fingerprint, state: "seen", thesis: nil, now: Time.now)
        entry = fingerprints[fingerprint] ||= { "first_seen" => now.utc.iso8601 }
        entry["last_seen"] = now.utc.iso8601
        entry["state"] = state
        if thesis
          entry["feature_id"] = thesis.feature_id.to_s
          entry["title_tokens"] = title_tokens(thesis)
        end
        fingerprints
      end

      def title_tokens(thesis)
        normalize_token([ thesis.problem, thesis.proposed_refactor ].compact.join(" ")).split
      end

      def overlap_coefficient(tokens_a, tokens_b)
        set_a = tokens_a.to_set
        set_b = tokens_b.to_set
        smaller = [ set_a.size, set_b.size ].min
        return 0.0 if smaller.zero?

        (set_a & set_b).size.to_f / smaller
      end

      def normalized_path(path)
        path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
      end

      def normalize_token(text)
        text.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip.split.first(60).join(" ")
      end
    end
  end
end
