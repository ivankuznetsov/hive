require "json"
require "open3"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/patrol/dismissals"
require "hive/patrol/fingerprint"
require "hive/patrol/fixer"
require "hive/patrol/mapper"
require "hive/patrol/pr_opener"
require "hive/patrol/reviewer"
require "hive/patrol/state_store"

module Hive
  module Commands
    class Patrol
      FIXABLE_SEVERITIES = %w[critical high medium].freeze

      def initialize(project, json: false, dry_run: false,
                     mapper_factory: nil, reviewer_factory: nil,
                     fixer_factory: nil, pr_opener_factory: nil,
                     dismissals_factory: nil)
        @project = project
        @json = json
        @dry_run = dry_run
        @mapper_factory = mapper_factory || ->(root, cfg, state) { Hive::Patrol::Mapper.new(root, cfg: cfg, state: state) }
        @reviewer_factory = reviewer_factory || ->(root, cfg, state) { Hive::Patrol::Reviewer.new(root, cfg: cfg, state: state) }
        @fixer_factory = fixer_factory || ->(root, cfg, state) { Hive::Patrol::Fixer.new(root, cfg: cfg, state: state) }
        @pr_opener_factory = pr_opener_factory || ->(root, cfg, state) { Hive::Patrol::PrOpener.new(root, cfg: cfg, state: state) }
        @dismissals_factory = dismissals_factory || ->(root, state) { Hive::Patrol::Dismissals.new(root, state: state) }
      end

      def call
        payload = run_cycle
        emit(payload)
      rescue Hive::Error => e
        emit_error(e)
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error(wrapped)
        raise wrapped
      end

      private

      def run_cycle
        entry = Hive::Config.find_project(@project)
        raise Hive::ConfigError, "hive patrol: unknown project #{@project.inspect}" unless entry

        project_root = entry.fetch("path")
        cfg = Hive::Config.load(project_root)
        state = Hive::Patrol::StateStore.new(project_root)
        state.ensure!
        dismissed = @dismissals_factory.call(project_root, state).reconcile
        features = @mapper_factory.call(project_root, cfg, state).call
        reviewer = @reviewer_factory.call(project_root, cfg, state)
        findings = stamp_fingerprints(reviewer.call(features), project_root)

        fingerprints = state.fingerprints
        skipped = []
        candidates = findings.select do |finding|
          skip_reason = skip_reason(finding, fingerprints, dismissed, cfg)
          skipped << { "finding_id" => finding.id, "fingerprint" => finding.fingerprint, "reason" => skip_reason } if skip_reason
          skip_reason.nil?
        end

        # `max_prs_per_cycle` caps PRs opened per scan, not fix candidates.
        # Capping candidates before fixing meant a failed validation
        # consumed the budget and an otherwise-fixable later candidate was
        # never attempted. Keep attempting candidates in order until that
        # many PRs are actually opened.
        max_prs = cfg.dig("patrol", "max_prs_per_cycle") || 3
        fixes = []
        pr_results = []
        unless @dry_run
          fixer = @fixer_factory.call(project_root, cfg, state)
          pr_opener = @pr_opener_factory.call(project_root, cfg, state)
          prs_opened = 0
          candidates.each do |finding|
            break if prs_opened >= max_prs

            patch = fixer.attempt(finding)
            fixes << patch
            next unless patch.passed

            result = pr_opener.open(finding, patch)
            pr_results << result
            prs_opened += 1 if result.opened?
          end
        end

        # Only advance the scanned-SHA watermark when every feature
        # reviewed cleanly. If any feature's reviewer agent failed or
        # returned malformed JSON, leaving last_scanned_sha unchanged lets
        # the next cycle re-review this commit instead of treating a
        # partial scan as a clean pass and never looking again (U5).
        now_iso = Time.now.utc.iso8601
        if reviewer_errored?(reviewer)
          state.update_state("last_run_at" => now_iso)
          scanned_sha = state.state["last_scanned_sha"].to_s
        else
          scanned_sha = current_default_sha(project_root, cfg)
          state.update_state("last_run_at" => now_iso, "last_scanned_sha" => scanned_sha)
        end
        success_payload(entry, project_root, scanned_sha, features, findings, candidates, fixes, pr_results, skipped)
      end

      def reviewer_errored?(reviewer)
        reviewer.respond_to?(:review_errors) && Array(reviewer.review_errors).any?
      end

      def stamp_fingerprints(findings, project_root)
        findings.each do |finding|
          finding.fingerprint ||= Hive::Patrol::Fingerprint.compute(finding, project_root: project_root)
        end
      end

      def skip_reason(finding, fingerprints, dismissed, cfg)
        return "dismissed" if Hive::Patrol::Fingerprint.dismissed?(dismissed, finding.fingerprint)
        return "existing_pr" if Hive::Patrol::Fingerprint.known_active?(fingerprints, finding.fingerprint)
        # The exact fingerprint above only catches byte-identical re-files.
        # The similarity gate catches the common case: the agent re-words
        # the same issue (different feature/title/snippet) each scan, so its
        # fingerprint differs and it would otherwise be re-opened forever.
        return "similar_to_existing" if Hive::Patrol::Fingerprint.similar_known?(fingerprints, dismissed, finding)
        return "low_confidence" unless Hive::Patrol::Fingerprint.fixable_confidence?(finding, cfg.dig("patrol", "min_confidence_to_fix"))
        return "low_severity" unless FIXABLE_SEVERITIES.include?(finding.severity.to_s)

        nil
      end

      def current_default_sha(project_root, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        out, err, status = Open3.capture3("git", "-C", project_root, "rev-parse", branch)
        raise Hive::GitError, "git rev-parse #{branch} failed: #{err.strip.empty? ? out : err}" unless status.success?

        out.strip
      end

      def success_payload(entry, project_root, sha, features, findings, candidates, fixes, pr_results, skipped)
        opened = pr_results.select(&:opened?)
        {
          "schema" => "hive-patrol",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-patrol"),
          "ok" => true,
          "project" => entry.fetch("name"),
          "project_root" => project_root,
          "dry_run" => @dry_run,
          "features_mapped" => features.size,
          "findings" => findings.size,
          "fix_candidates" => candidates.size,
          "fixes_attempted" => fixes.size,
          "fixes_validated" => fixes.count(&:passed),
          "prs_opened" => opened.size,
          "pr_urls" => opened.map(&:pr_url),
          "skipped_findings" => skipped,
          "last_scanned_sha" => sha
        }
      end

      def emit(payload)
        if @json
          puts JSON.generate(payload)
        else
          puts "hive patrol: #{payload['project']} mapped=#{payload['features_mapped']} " \
               "findings=#{payload['findings']} fixes=#{payload['fixes_validated']} " \
               "prs=#{payload['prs_opened']}"
        end
        payload
      end

      def emit_error(error)
        return unless @json

        puts JSON.generate(
          "schema" => "hive-patrol",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-patrol"),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "error",
          "exit_code" => error.exit_code,
          "message" => error.message
        )
      end
    end
  end
end
