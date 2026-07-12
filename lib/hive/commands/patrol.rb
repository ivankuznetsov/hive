require "json"
require "open3"
require "securerandom"
require "tmpdir"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/patrol/candidate_selector"
require "hive/patrol/dismissals"
require "hive/patrol/fingerprint"
require "hive/patrol/fixer"
require "hive/patrol/feature_batch"
require "hive/patrol/mapper"
require "hive/patrol/pr_opener"
require "hive/patrol/reviewer"
require "hive/patrol/state_store"

module Hive
  module Commands
    class Patrol
      FIX_RESULT_REASONS = (
        %w[validated validation_failed] + Hive::Patrol::Fixer::FAILURE_REASONS
      ).uniq.freeze

      def initialize(project, json: false, dry_run: false,
                     mapper_factory: nil, reviewer_factory: nil,
                     fixer_factory: nil, pr_opener_factory: nil,
                     dismissals_factory: nil)
        @project = project
        @json = json
        @dry_run = dry_run
        @mapper_factory = mapper_factory || lambda do |root, cfg, state|
          Hive::Patrol::Mapper.new(root, cfg: cfg, state: state, capabilities: [ :architecture ])
        end
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
        target_sha = sweep_target_sha(project_root, cfg, state)
        features, feature_batch, reviewer, findings = with_scan_checkout(project_root, target_sha) do |scan_root|
          mapped = @mapper_factory.call(scan_root, cfg, state).call
          batch = Hive::Patrol::FeatureBatch.new(cfg: cfg, state: state).call(
            mapped, target_sha: target_sha
          )
          scan_reviewer = @reviewer_factory.call(scan_root, cfg, state)
          reviewed = stamp_fingerprints(scan_reviewer.call(batch.features), scan_root)
          [ mapped, batch, scan_reviewer, reviewed ]
        end
        review = review_outcome(feature_batch, reviewer)

        fingerprints = state.fingerprints
        candidates, skipped = Hive::Patrol::CandidateSelector.new(
          cfg: cfg,
          fingerprints: fingerprints,
          dismissed: dismissed
        ).call(findings)
        # Reviewer persists before portfolio scoring because it operates one
        # feature at a time. Rewrite only scored records; base-gated findings
        # retain their immutable first write and avoid a no-op second write.
        findings.select { |finding| !finding.alpha_score.nil? }.each { |finding| state.write_finding(finding) }
        write_selection_audit(state, candidates, skipped)

        # `max_prs_per_cycle` caps PRs opened per scan, not fix candidates.
        # Capping candidates before fixing meant a failed validation
        # consumed the budget and an otherwise-fixable later candidate was
        # never attempted. Keep attempting candidates in order until that
        # many PRs are actually opened.
        max_prs = cfg.dig("patrol", "max_prs_per_cycle") || 3
        max_attempts = cfg.dig("patrol", "max_fix_attempts_per_cycle") || 6
        fixes = []
        pr_results = []
        fix_results = []
        unless @dry_run
          fixer = @fixer_factory.call(project_root, cfg, state)
          pr_opener = @pr_opener_factory.call(project_root, cfg, state)
          prs_opened = 0
          candidates.each do |finding|
            break if prs_opened >= max_prs || fixes.size >= max_attempts

            patch = fixer.attempt(finding)
            fixes << patch
            outcome = fix_outcome(finding, patch)
            fix_results << outcome
            next unless patch.passed

            result = pr_opener.open(finding, patch)
            pr_results << result
            outcome["publication_status"] = result.status.to_s
            outcome["publication_reason"] = result.reason
            outcome["publication_detail"] = result.detail
            outcome["pr_url"] = result.pr_url
            prs_opened += 1 if result.opened?
          end
        end

        # Only advance the scanned-SHA watermark when every feature
        # reviewed cleanly. If any feature's reviewer agent failed or
        # returned malformed JSON, leaving last_scanned_sha unchanged lets
        # the next cycle re-review this commit instead of treating a
        # partial scan as a clean pass and never looking again (U5).
        now_iso = Time.now.utc.iso8601
        if review.fetch("review_errors").any?
          state.update_state("last_run_at" => now_iso)
          scanned_sha = state.state["last_scanned_sha"].to_s
        elsif feature_batch.complete
          scanned_sha = target_sha
          state.update_state(
            "last_run_at" => now_iso,
            "last_scanned_sha" => scanned_sha,
            "feature_review_sha" => target_sha,
            "feature_review_cursor" => 0
          )
        else
          scanned_sha = state.state["last_scanned_sha"].to_s
          state.update_state(
            "last_run_at" => now_iso,
            "feature_review_sha" => target_sha,
            "feature_review_cursor" => feature_batch.next_cursor
          )
        end
        success_payload(
          entry, project_root, scanned_sha, features, review,
          findings, candidates, fixes, fix_results, pr_results, skipped
        )
      end

      def review_outcome(feature_batch, reviewer)
        attempted = feature_batch.features.size
        errors = reviewer.respond_to?(:review_errors) ? Array(reviewer.review_errors) : []
        attempted_ids = feature_batch.features.map { |feature| feature.id.to_s }
        failed_ids = errors.filter_map do |error|
          next unless error.is_a?(Hash)

          id = (error["feature_id"] || error[:feature_id]).to_s
          id if attempted_ids.include?(id)
        end.uniq
        # An un-attributable error makes the successful count unknowable. Fail
        # closed instead of claiming that every attempted feature completed.
        succeeded = errors.any? && failed_ids.size != errors.size ? 0 : attempted - failed_ids.size
        {
          "features_review_attempted" => attempted,
          "features_reviewed" => succeeded,
          "review_complete" => errors.empty? && feature_batch.complete,
          "review_errors" => errors
        }
      end

      def stamp_fingerprints(findings, project_root)
        findings.each do |finding|
          finding.fingerprint ||= Hive::Patrol::Fingerprint.compute(finding, project_root: project_root)
        end
      end

      def current_default_sha(project_root, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        out, err, status = Open3.capture3("git", "-C", project_root, "rev-parse", branch)
        raise Hive::GitError, "git rev-parse #{branch} failed: #{err.strip.empty? ? out : err}" unless status.success?

        out.strip
      end

      def sweep_target_sha(project_root, cfg, state)
        snapshot = state.state
        cursor = snapshot["feature_review_cursor"].to_i
        active_sha = snapshot["feature_review_sha"].to_s
        return active_sha if cursor.positive? && !active_sha.empty?

        current_default_sha(project_root, cfg)
      end

      def with_scan_checkout(project_root, target_sha)
        Dir.mktmpdir("hive-patrol-scan-") do |parent|
          scan_root = File.join(parent, "checkout")
          attached = false
          git_output!(project_root, "worktree", "add", "--detach", scan_root, target_sha)
          attached = true
          actual_sha = git_output!(scan_root, "rev-parse", "HEAD").strip
          unless actual_sha == target_sha
            raise Hive::GitError,
                  "patrol scan checkout resolved #{actual_sha.inspect}, expected #{target_sha.inspect}"
          end

          result = yield scan_root
          assert_clean_scan_checkout!(scan_root, target_sha)
          result
        ensure
          remove_scan_checkout!(project_root, scan_root) if attached
        end
      end

      def assert_clean_scan_checkout!(scan_root, target_sha)
        observed_sha = git_output!(scan_root, "rev-parse", "HEAD").strip
        unless observed_sha == target_sha
          raise Hive::GitError, "patrol reviewer changed its detached scan commit"
        end

        status = git_output!(scan_root, "status", "--porcelain", "--untracked-files=all")
        return if status.empty?

        raise Hive::GitError, "patrol reviewer modified its detached scan checkout"
      end

      def remove_scan_checkout!(project_root, scan_root)
        git_output!(project_root, "worktree", "remove", "--force", scan_root)
      end

      def git_output!(root, *args)
        out, err, status = Open3.capture3("git", "-C", root, *args)
        return out if status.success?

        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise Hive::GitError, "git #{args.join(' ')} failed: #{detail}"
      end

      def write_selection_audit(state, candidates, skipped)
        now = Time.now.utc
        id = "selection-#{now.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
        state.write_run_log(id, {
          "schema" => "hive-patrol-selection",
          "schema_version" => 1,
          "created_at" => now.iso8601,
          "ranked_candidates" => candidates.map do |finding|
            {
              "finding_id" => finding.id,
              "feature_id" => finding.feature_id,
              "fingerprint" => finding.fingerprint,
              "category" => finding.category,
              "alpha_score" => finding.alpha_score
            }
          end,
          "skipped" => skipped
        })
      end

      def fix_outcome(finding, patch)
        raw_reason = patch.validation["reason"].to_s
        reason = raw_reason.empty? ? (patch.passed ? "validated" : "validation_failed") : raw_reason
        detail = patch.validation["error"]&.to_s
        unless FIX_RESULT_REASONS.include?(reason)
          detail = [ detail, "unrecognized fixer reason #{reason.inspect}" ].compact.join(": ")
          reason = "fix_error"
        end
        {
          "finding_id" => finding.id,
          "patch_id" => patch.id,
          "passed" => patch.passed == true,
          "reason" => reason,
          "detail" => detail,
          "patch_artifact" => File.join(".hive-state", "patrol", "patches", "#{patch.id}.json"),
          "publication_status" => nil,
          "publication_reason" => nil,
          "publication_detail" => nil,
          "pr_url" => nil
        }
      end

      def success_payload(entry, project_root, sha, features, review, findings, candidates,
                          fixes, fix_results, pr_results, skipped)
        opened = pr_results.select(&:opened?)
        handoff_errors = pr_results.select(&:review_handoff_failed?).map do |result|
          { "pr_url" => result.pr_url, "reason" => result.reason }
        end
        {
          "schema" => "hive-patrol",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-patrol"),
          "ok" => true,
          "project" => entry.fetch("name"),
          "project_root" => project_root,
          "dry_run" => @dry_run,
          "features_mapped" => features.size,
          "features_review_attempted" => review.fetch("features_review_attempted"),
          "features_reviewed" => review.fetch("features_reviewed"),
          "review_complete" => review.fetch("review_complete"),
          "review_errors" => review.fetch("review_errors"),
          "findings" => findings.size,
          "fix_candidates" => candidates.size,
          "fixes_attempted" => fixes.size,
          "fixes_validated" => fixes.count(&:passed),
          "prs_opened" => opened.size,
          "pr_urls" => opened.map(&:pr_url),
          "review_handoff_errors" => handoff_errors,
          "fix_results" => fix_results,
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
