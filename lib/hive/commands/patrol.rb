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
require "hive/patrol/finding_registry"
require "hive/patrol/fixer"
require "hive/patrol/feature_batch"
require "hive/patrol/mapper"
require "hive/patrol/pr_opener"
require "hive/patrol/reviewer"
require "hive/patrol/state_store"
require "hive/patrol/token_budget"
require "hive/patrol/validator"
require "hive/worktree"

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
        @reviewer_factory = reviewer_factory
        @fixer_factory = fixer_factory
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
        ensure_validation_configured!(cfg) unless @dry_run
        state = Hive::Patrol::StateStore.new(project_root)
        state.ensure!
        token_budget = Hive::Patrol::TokenBudget.new(project_root, cfg: cfg)
        dismissed = @dismissals_factory.call(project_root, state).reconcile
        target_sha = sweep_target_sha(project_root, cfg, state)
        features, feature_batch, reviewer, findings = with_scan_checkout(project_root, target_sha) do |scan_root|
          mapped = @mapper_factory.call(scan_root, cfg, state).call
          batch = Hive::Patrol::FeatureBatch.new(cfg: cfg, state: state).call(
            mapped, target_sha: target_sha, limit: review_launch_limit(token_budget, cfg)
          )
          scan_reviewer = build_reviewer(scan_root, cfg, state, token_budget)
          reviewed = stamp_findings(
            scan_reviewer.call(batch.features), scan_root,
            target_sha: target_sha, cfg: cfg
          )
          [ mapped, batch, scan_reviewer, reviewed ]
        end
        review = review_outcome(feature_batch, reviewer)

        fingerprints = state.fingerprints
        registry = Hive::Patrol::FindingRegistry.new(state: state, target_sha: target_sha)
        registry.reconcile!(fingerprints: fingerprints, dismissed: dismissed)
        admission = registry.admit(findings)
        findings = admission.findings
        candidates, skipped = Hive::Patrol::CandidateSelector.new(
          cfg: cfg,
          fingerprints: fingerprints,
          dismissed: dismissed
        ).call(findings)
        skipped.concat(admission.skipped)
        # Persist only after target binding, semantic deduplication, lifecycle
        # admission, and portfolio scoring. The reviewer itself is a pure
        # producer and cannot accumulate untriaged duplicates.
        findings.each { |finding| state.write_finding(finding) }
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
          fixer = build_fixer(project_root, cfg, state, token_budget)
          pr_opener = @pr_opener_factory.call(project_root, cfg, state)
          prs_opened = 0
          candidates.each do |finding|
            break if prs_opened >= max_prs || fixes.size >= max_attempts

            patch = fixer.attempt(finding)
            fixes << patch
            outcome = fix_outcome(finding, patch)
            fix_results << outcome
            update_finding_lifecycle(registry, finding, outcome.fetch("reason"))
            break if terminal_patrol_exhaustion?(patch)
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
          state.update_state(
            "last_run_at" => now_iso,
            "feature_review_active" => true,
            "feature_review_sha" => target_sha,
            "feature_review_cursor" => retry_feature_cursor(
              feature_batch, review.fetch("review_errors")
            )
          )
          scanned_sha = state.state["last_scanned_sha"].to_s
        elsif feature_batch.complete
          scanned_sha = target_sha
          state.update_state(
            "last_run_at" => now_iso,
            "last_scanned_sha" => scanned_sha,
            "feature_review_active" => false,
            "feature_review_sha" => target_sha,
            "feature_review_cursor" => 0
          )
        else
          scanned_sha = state.state["last_scanned_sha"].to_s
          state.update_state(
            "last_run_at" => now_iso,
            "feature_review_active" => true,
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
        failed_indices = review_failure_indices(feature_batch, errors)
        # An un-attributable error makes the successful count unknowable. Fail
        # closed instead of claiming that every attempted feature completed.
        succeeded = if errors.any? && failed_indices.nil?
          0
        else
          attempted - Array(failed_indices).size
        end
        {
          "features_review_attempted" => attempted,
          "features_reviewed" => succeeded,
          "review_complete" => errors.empty? && feature_batch.complete,
          "review_errors" => errors
        }
      end

      # Reviewer calls consume the same cycle and daily launch envelope as
      # fixers. Bound the selected feature batch to launches that can actually
      # happen and, for a shipping cycle, reserve as much configured fix-attempt
      # capacity as the current envelope permits. A zero- or one-launch
      # remainder still selects one feature so review can progress or report
      # the exact budget exhaustion instead of presenting an empty batch as
      # complete.
      def review_launch_limit(token_budget, cfg)
        available = token_budget.remaining_launches
        return [ available, 1 ].max if @dry_run

        desired_fix_launches = cfg.dig("patrol", "max_fix_attempts_per_cycle").to_i
        fix_launches = [ desired_fix_launches, [ available - 1, 0 ].max ].min
        [ available - fix_launches, 1 ].max
      end

      def terminal_patrol_exhaustion?(patch)
        exhaustion = patch.validation["resource_exhaustion"] || patch.validation[:resource_exhaustion]
        reason = exhaustion.is_a?(Hash) && (exhaustion["reason"] || exhaustion[:reason]).to_s
        %w[
          cycle_agent_spawn_limit daily_agent_spawn_limit
          cycle_token_limit daily_token_limit usage_store_unavailable
        ].include?(reason)
      end

      # A later feature failure must pin that feature, not replay already-clean
      # leading features. Unattributable errors still fail closed at the batch
      # start because Hive cannot prove which feature completed.
      def retry_feature_cursor(feature_batch, errors)
        failed_indices = review_failure_indices(feature_batch, Array(errors))
        return feature_batch.start_cursor unless failed_indices

        feature_batch.start_cursor + failed_indices.min.to_i
      end

      def review_failure_indices(feature_batch, errors)
        attempted_ids = feature_batch.features.map { |feature| feature.id.to_s }
        indices = errors.filter_map do |error|
          next unless error.is_a?(Hash)

          id = (error["feature_id"] || error[:feature_id]).to_s
          attempted_ids.index(id)
        end
        return unless indices.size == errors.size && indices.uniq.size == errors.size

        indices
      end

      def build_reviewer(root, cfg, state, token_budget)
        return @reviewer_factory.call(root, cfg, state) if @reviewer_factory

        Hive::Patrol::Reviewer.new(root, cfg: cfg, state: state, token_budget: token_budget)
      end

      def build_fixer(root, cfg, state, token_budget)
        return @fixer_factory.call(root, cfg, state) if @fixer_factory

        Hive::Patrol::Fixer.new(root, cfg: cfg, state: state, token_budget: token_budget)
      end

      def ensure_validation_configured!(cfg)
        commands = cfg.dig("patrol", "commands")
        return if Hive::Patrol::Validator.new(commands).configured?

        raise Hive::ConfigError,
              "patrol.commands must configure at least one of docs, format, lint, public_contract, typecheck, or test before fixes can run"
      end

      def stamp_findings(findings, project_root, target_sha:, cfg:)
        configured_keys = Hive::Patrol::Validator::COMMAND_NAMES.select do |name|
          command = cfg.dig("patrol", "commands", name)
          command.is_a?(String) && !command.strip.empty?
        end
        findings.each do |finding|
          finding.fingerprint ||= Hive::Patrol::Fingerprint.compute(finding, project_root: project_root)
          finding.target_sha = target_sha
          finding.validation_key ||= configured_keys.first if configured_keys.one?
        end
      end

      def update_finding_lifecycle(registry, finding, reason)
        case reason
        when "stale_target_sha"
          registry.transition_current!(finding, state: "superseded", reason: reason)
        end
      end

      def current_default_sha(project_root, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        ref = branch
        if Hive::Worktree.origin_configured?(project_root)
          out, err, status = Hive::Worktree.fetch_origin_branch(project_root, branch)
          unless status.success?
            detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
            raise Hive::GitError,
                  "cannot fetch fresh patrol scan base origin/#{branch}: #{detail}"
          end
          ref = "refs/remotes/origin/#{branch}"
        end

        out, err, status = Open3.capture3(
          "git", "-C", project_root, "rev-parse", "--verify", "#{ref}^{commit}"
        )
        unless status.success?
          detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
          raise Hive::GitError, "git rev-parse #{ref} failed: #{detail}"
        end

        sha = out.strip
        unless sha.match?(/\A[0-9a-f]{40,64}\z/i)
          raise Hive::GitError, "fresh patrol scan base resolved an invalid SHA"
        end

        sha.downcase
      end

      def sweep_target_sha(project_root, cfg, state)
        snapshot = state.state
        cursor = snapshot["feature_review_cursor"].to_i
        active_sha = snapshot["feature_review_sha"].to_s
        active = snapshot["feature_review_active"] == true
        legacy_active = !snapshot.key?("feature_review_active") && cursor.positive?
        if (active || legacy_active) && materializable_commit?(project_root, active_sha)
          return active_sha.downcase
        end

        current_default_sha(project_root, cfg)
      end

      def materializable_commit?(project_root, sha)
        return false unless sha.match?(/\A[0-9a-f]{40,64}\z/i)

        _out, _err, status = Open3.capture3(
          "git", "-C", project_root, "rev-parse", "--verify", "#{sha}^{commit}"
        )
        status.success?
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

      # Cleanup failure must never mask the scan outcome: raising here would
      # replace an in-flight reviewer exception (losing its cause) or — worse —
      # discard a SUCCESSFULLY completed review cycle as an internal error.
      # A leaked checkout is recoverable (each cycle creates a fresh
      # Dir.mktmpdir path, so stale worktree metadata cannot collide with or
      # corrupt the next scan and `git worktree prune` reclaims it); a
      # discarded clean review cycle is not. Warn and continue.
      def remove_scan_checkout!(project_root, scan_root)
        git_output!(project_root, "worktree", "remove", "--force", scan_root)
      rescue Hive::GitError => e
        warn "hive patrol: failed to remove detached scan checkout #{scan_root}: #{e.message}"
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
              "alpha_score" => finding.alpha_score,
              "target_sha" => finding.target_sha,
              "validation_key" => finding.validation_key
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
