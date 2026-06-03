require "digest"

module Hive
  module Patrol
    module Fingerprint
      CONFIDENCE_ORDER = { "low" => 0, "medium" => 1, "high" => 2 }.freeze

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
        Digest::SHA256.hexdigest(payload)
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

      def record_seen(fingerprints, fingerprint, branch: nil, pr_url: nil, state: "seen", now: Time.now)
        entry = fingerprints[fingerprint] ||= { "first_seen" => now.utc.iso8601 }
        entry["last_seen"] = now.utc.iso8601
        entry["branch"] = branch if branch
        entry["pr_url"] = pr_url if pr_url
        entry["state"] = state
        fingerprints
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
