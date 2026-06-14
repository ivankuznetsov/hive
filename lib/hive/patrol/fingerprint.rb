require "digest"
require "set"

module Hive
  module Patrol
    module Fingerprint
      CONFIDENCE_ORDER = { "low" => 0, "medium" => 1, "high" => 2 }.freeze

      # The exact fingerprint is agent-volatile: the same underlying issue
      # is re-filed each scan with a different feature attribution, title
      # wording, and code snippet, so the SHA never matches a prior PR and
      # patrol re-opens the same finding forever. The similarity gate is the
      # real dedup: a new finding in the SAME category whose normalized
      # title tokens overlap an already-PR'd/dismissed finding by at least
      # this coefficient (intersection / smaller-set) is treated as the same
      # issue and skipped. 0.6 catches the observed re-words (e.g. "allows
      # implicit POST mutations" vs "allows implicit POST requests" vs
      # "dry-run check misses implicit POST") without collapsing unrelated
      # findings.
      SIMILARITY_THRESHOLD = 0.6

      module_function

      def compute(finding, project_root:)
        evidence = Array(finding.evidence).first || {}
        path = normalized_path(evidence["file"] || evidence[:file])
        token = anchor_token(finding, evidence, project_root, path)
        payload = [
          finding.feature_id.to_s,
          finding.category.to_s,
          path,
          token
        ].join("\0")
        ::Digest::SHA256.hexdigest(payload)
      end

      def fixable_confidence?(finding, minimum)
        CONFIDENCE_ORDER.fetch(finding.confidence.to_s, -1) >= CONFIDENCE_ORDER.fetch(minimum.to_s, 1)
      end

      def known_active?(fingerprints, fingerprint)
        state = fingerprints.dig(fingerprint, "state")
        %w[open merged resolved].include?(state)
      end

      def dismissed?(dismissed, fingerprint)
        dismissed.key?(fingerprint)
      end

      def record_seen(fingerprints, fingerprint, branch: nil, pr_url: nil, state: "seen",
                      finding: nil, now: Time.now)
        entry = fingerprints[fingerprint] ||= { "first_seen" => now.utc.iso8601 }
        entry["last_seen"] = now.utc.iso8601
        entry["branch"] = branch if branch
        entry["pr_url"] = pr_url if pr_url
        entry["state"] = state
        # Persist the finding's category + normalized title tokens so the
        # similarity gate can recognise a re-worded re-file of this issue
        # on a later scan even though its exact fingerprint will differ.
        if finding
          entry["category"] = finding.category.to_s
          entry["title_tokens"] = title_tokens(finding)
        end
        fingerprints
      end

      # Normalized word list of a finding's title, used as the similarity
      # signal (titles are the most stable semantic handle the agent emits,
      # even though the exact wording drifts run-to-run).
      def title_tokens(finding)
        normalize_token(finding.title).split
      end

      # True when `finding` is the same issue as one already PR'd
      # (open/merged) or dismissed — judged by same category + title-token
      # overlap coefficient >= SIMILARITY_THRESHOLD. Only entries that
      # carry stored content (recorded since this feature shipped) can
      # match; older content-less entries are skipped (their exact
      # fingerprint still guards them via known_active?/dismissed?).
      def similar_known?(fingerprints, dismissed, finding)
        tokens = title_tokens(finding)
        return false if tokens.empty?

        category = finding.category.to_s
        active = fingerprints.values.select { |e| %w[open merged resolved].include?(e["state"]) }
        (active + dismissed.values).any? do |entry|
          next false unless entry["category"].to_s == category

          other = Array(entry["title_tokens"]).map(&:to_s)
          next false if other.empty?

          overlap_coefficient(tokens, other) >= SIMILARITY_THRESHOLD
        end
      end

      # Szymkiewicz–Simpson overlap: |A ∩ B| / min(|A|, |B|). More robust
      # than Jaccard for catching a re-worded title that adds/drops a few
      # tokens around a shared core.
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

      def anchor_token(finding, evidence, project_root, path)
        explicit = evidence["snippet"] || evidence[:snippet] || evidence["code"] || evidence[:code]
        return normalize_token(explicit) unless explicit.to_s.strip.empty?

        line = (evidence["line"] || evidence[:line]).to_i
        code = snippet_at(project_root, path, line)
        return normalize_token(code) unless code.empty?

        normalize_token([ finding.title, finding.description, finding.recommendation ].compact.join(" "))
      end

      def snippet_at(project_root, path, line)
        return "" if path.empty? || line <= 0

        full = safe_repo_path(project_root, path)
        return "" if full.nil?

        lines = File.readlines(full, chomp: true)
        start = [ line - 2, 0 ].max
        lines[start, 3].join(" ")
      rescue SystemCallError, ArgumentError
        ""
      end

      # Constrain an agent-supplied evidence path to a file inside the
      # project. `normalized_path` only strips a leading `./` and
      # backslashes, so `../../etc/passwd` or `/etc/passwd` would otherwise
      # escape the repo. Resolve against the root and reject anything that
      # lands outside it.
      def safe_repo_path(project_root, path)
        return nil if path.start_with?("/")

        root = File.expand_path(project_root)
        full = File.expand_path(File.join(root, path))
        return nil unless full == root || full.start_with?(root + File::SEPARATOR)

        full
      end

      def normalize_token(text)
        text.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip.split.first(40).join(" ")
      end
    end
  end
end
