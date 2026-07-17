require "digest"
require "set"

module Hive
  module Patrol
    module Fingerprint
      CONFIDENCE_ORDER = { "low" => 0, "medium" => 1, "high" => 2 }.freeze
      RETRYABLE_PUBLICATION_STATES = %w[reconciliation_pending review_handoff_failed].freeze

      # Structured exact fingerprints are independent of feature_id (and of
      # title/snippet wording), but they DO pin the first evidence path — and
      # Reviewer#prioritize_slice_evidence reorders evidence before compute,
      # so re-attribution that changes the leading path changes the SHA. They
      # also remain sensitive to contract/root-cause wording. similar_known?
      # is the fuzzy fallback for both kinds of drift: a new finding in the
      # SAME category whose normalized title or root-cause tokens overlap an
      # already-PR'd/dismissed finding by at least this coefficient is treated
      # as the same issue. 0.6 catches observed re-words without collapsing
      # unrelated findings.
      SIMILARITY_THRESHOLD = 0.6
      LEGACY_GROUPED_FEATURE_PREFIXES = {
        "command-package-json-scripts" => "command-npm-script-",
        "command-pyproject-scripts" => "command-python-script-",
        "command-package-swift-executables" => "command-swift-executable-"
      }.freeze
      LEGACY_PACKAGE_MANIFESTS = %w[
        package.json Gemfile pyproject.toml go.mod Cargo.toml Package.swift
        composer.json mix.exs
      ].freeze

      module_function

      def compute(finding, project_root:)
        evidence = Array(finding.evidence).first || {}
        path = normalized_path(evidence["file"] || evidence[:file])
        contract = normalize_token(finding.respond_to?(:contract) ? finding.contract : nil)
        root_cause = normalize_token(finding.respond_to?(:root_cause) ? finding.root_cause : nil)
        payload = if !contract.empty? && !root_cause.empty?
                    # New structured findings exclude feature_id, so only
                    # feature attribution independence is guaranteed. The
                    # payload still pins the FIRST evidence path (which
                    # Reviewer#prioritize_slice_evidence reorders before
                    # compute), so re-attribution that changes the leading
                    # path changes this SHA, as does contract/root-cause
                    # wording; similar_known? is the fuzzy fallback for both.
                    [ finding.category.to_s, path, contract, root_cause ].join("\0")
        else
          token = anchor_token(finding, evidence, project_root, path)
          [ finding.feature_id.to_s, finding.category.to_s, path, token ].join("\0")
        end
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

      # Feature ids changed when per-route/per-manifest slices were replaced
      # by language-neutral components and grouped command manifests. Match a
      # historical id only to the current finding that owns the same primary
      # path (or to a known grouped-manifest predecessor); never use a global
      # "any old patrol PR" gate.
      def same_feature_history?(historical_feature_id, finding)
        historical = historical_feature_id.to_s
        current = finding.feature_id.to_s
        return false if historical.empty? || current.empty?
        return true if historical == current

        legacy_prefix = LEGACY_GROUPED_FEATURE_PREFIXES[current]
        return true if legacy_prefix && historical.start_with?(legacy_prefix)
        return false unless current.start_with?("architecture-")

        path = primary_evidence_path(finding)
        return false if path.empty?
        return true if historical == legacy_stable_id("route", path)

        LEGACY_PACKAGE_MANIFESTS.include?(path) && historical == legacy_stable_id("package", path)
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
          entry["feature_id"] = finding.feature_id.to_s
          entry["title_tokens"] = title_tokens(finding)
          root_cause = semantic_tokens(finding)
          entry["root_cause_tokens"] = root_cause unless root_cause.empty?
        end
        fingerprints
      end

      # Normalized word list of a finding's title, used as the similarity
      # signal (titles are the most stable semantic handle the agent emits,
      # even though the exact wording drifts run-to-run).
      def title_tokens(finding)
        normalize_token(finding.title).split
      end

      # Groups the active (open/merged/resolved) and dismissed ledger entries
      # by category for similar_known? lookups.
      def similarity_index(fingerprints, dismissed)
        active = fingerprints.values.select { |entry| %w[open merged resolved].include?(entry["state"]) }
        (active + dismissed.values).group_by { |entry| entry["category"].to_s }
      end

      # True when `finding` is the same issue as one already PR'd
      # (open/merged/resolved) or dismissed — judged by same category plus an
      # overlap coefficient >= SIMILARITY_THRESHOLD on EITHER the normalized
      # title tokens OR the normalized root-cause tokens. Only entries that
      # carry stored content (recorded since this feature shipped) can
      # match; older content-less entries are skipped (their exact
      # fingerprint still guards them via known_active?/dismissed?).
      def similar_known?(fingerprints, dismissed, finding, index: nil)
        tokens = title_tokens(finding)
        return false if tokens.empty?

        category = finding.category.to_s
        root_cause = semantic_tokens(finding)
        entries = (index || similarity_index(fingerprints, dismissed)).fetch(category, [])
        entries.any? do |entry|
          other = Array(entry["title_tokens"]).map(&:to_s)
          title_match = !other.empty? && overlap_coefficient(tokens, other) >= SIMILARITY_THRESHOLD
          other_root = Array(entry["root_cause_tokens"]).map(&:to_s)
          root_match = !root_cause.empty? && !other_root.empty? &&
                       overlap_coefficient(root_cause, other_root) >= SIMILARITY_THRESHOLD

          title_match || root_match
        end
      end

      def semantic_tokens(finding)
        return [] unless finding.respond_to?(:root_cause)

        normalize_token(finding.root_cause).split
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

      def primary_evidence_path(finding)
        evidence = Array(finding.evidence).first
        return "" unless evidence.is_a?(Hash)

        normalized_path(evidence["file"] || evidence[:file])
      end

      def legacy_stable_id(kind, path)
        slug = path.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
        "#{kind}-#{slug}"[0, 80]
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
        Array(lines[start, 3]).join(" ")
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
