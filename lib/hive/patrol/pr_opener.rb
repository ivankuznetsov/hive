require "tempfile"
require "time"
require "hive/gh"
require "hive/git_ops"
require "hive/patrol/fingerprint"
require "hive/patrol/review_handoff"
require "hive/patrol/state_store"
require "hive/secret_patterns"
require "hive/worktree"

module Hive
  module Patrol
    class PrOpener
      Result = Struct.new(:status, :pr_url, :reason, :review_task_path, keyword_init: true) do
        def opened?
          status == :opened
        end
      end

      def initialize(project_root, cfg:, state: StateStore.new(project_root), gh: Hive::Gh, review_handoff: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @gh = gh
        @review_handoff = review_handoff || ReviewHandoff.new(@project_root, cfg: cfg, state: state)
      end

      def open(finding, patch, now: Time.now)
        return Result.new(status: :skipped, reason: "validation_failed") unless patch.passed

        # Authenticate first: `lookup_prs_for_branch` shells out to `gh`
        # and raises GhError on an unauthenticated host, which surfaces a
        # less actionable error than the explicit auth check and (before
        # this) escaped unrescued — aborting the whole cycle after a fix
        # was already validated and its worktree created.
        @gh.ensure_authenticated!(@cfg)

        existing = @gh.lookup_prs_for_branch(patch.worktree_path, patch.branch).find do |pr|
          %w[OPEN MERGED].include?(pr["state"])
        end
        if existing
          record_mapping(finding, patch, existing["url"], existing["state"].downcase, now)
          # The branch already has a PR; this validated worktree is now
          # dead weight. Remove it so `.patrol/` doesn't accumulate one
          # leaked checkout per cycle.
          cleanup_worktree(patch)
          return Result.new(status: :skipped, pr_url: existing["url"], reason: "existing_pr")
        end

        body = body_for(finding, patch)
        secret_hits = Hive::SecretPatterns.scan(body) + Hive::SecretPatterns.scan(diff_for(patch.worktree_path))
        if secret_hits.any?
          # The diff that tripped the secret gate may contain credentials;
          # don't leave it on disk under the patrol worktree root.
          cleanup_worktree(patch)
          return Result.new(status: :blocked, reason: "secret_detected")
        end

        @gh.push_branch!(patch.worktree_path, patch.branch, cfg: @cfg)
        pr_url = create_pr(patch, body)
        record_mapping(finding, patch, pr_url, "open", now)
        review_task_path = enqueue_review_task(finding, patch, pr_url, now)
        if !review_task_path && @cfg.dig("patrol", "review_prs") == false
          # The branch is pushed; the local worktree is no longer needed
          # only when patrol is not handing the PR to 6-review.
          cleanup_worktree(patch)
        end
        Result.new(status: :opened, pr_url: pr_url, review_task_path: review_task_path)
      rescue Hive::GhError => e
        # A PR-stage failure after a validated fix would otherwise abort
        # the cycle and leak the passed-fix worktree (only the
        # validation-failure path removes it). Clean it up and surface a
        # structured error so one bad `gh` call doesn't accumulate
        # `.patrol` worktrees or sink the rest of the scan.
        cleanup_worktree(patch)
        Result.new(status: :error, reason: "gh_error: #{e.message}")
      end

      private

      def cleanup_worktree(patch)
        return unless patch.worktree_path

        Hive::Worktree.new(@project_root, "patrol-cleanup").remove!(path: patch.worktree_path, force: true)
      rescue StandardError
        nil
      end

      def enqueue_review_task(finding, patch, pr_url, now)
        @review_handoff.enqueue(finding: finding, patch: patch, pr_url: pr_url, now: now)
      rescue StandardError => e
        warn "hive: patrol opened #{pr_url} but failed to enqueue 6-review task: #{e.class}: #{e.message}"
        nil
      end

      def default_branch
        @cfg["default_branch"] || Hive::GitOps.new(@project_root).detect_default_branch
      end

      def create_pr(patch, body)
        Tempfile.create([ "hive-patrol-pr-", ".md" ]) do |file|
          file.write(body)
          file.flush
          args = [ "gh", "pr", "create", "--title", title_for(patch.finding),
                   "--body-file", file.path, "--head", patch.branch ]
          args << "--draft" if @cfg.dig("patrol", "draft_prs") != false
          out, err, status = @gh.capture3(*args, chdir: patch.worktree_path, cfg: @cfg)
          raise Hive::GhError, "gh pr create failed: #{err.strip.empty? ? out : err}" unless status.success?

          out.lines.last.to_s.strip
        end
      end

      def title_for(finding)
        "Hive patrol: #{finding.title || finding.id}"
      end

      def body_for(finding, patch)
        validation_lines = Array(patch.validation["commands"]).map do |cmd|
          "- #{cmd['name']}: #{cmd['exit_code'].to_i.zero? ? 'passed' : 'failed'} (`#{cmd['command']}`)"
        end
        evidence_lines = finding.evidence.map do |e|
          "- #{e['file'] || e[:file]}:#{e['line'] || e[:line]} #{e['snippet'] || e[:snippet]}"
        end

        <<~MD
          ## Hive Patrol Finding

          Slice: `#{finding.feature_id}`
          Category: `#{finding.category}`
          Severity: `#{finding.severity}`
          Confidence: `#{finding.confidence}`
          Fingerprint: `#{finding.fingerprint}`

          #{finding.description}

          ## Evidence

          #{evidence_lines.join("\n")}

          ## Applied Fix

          #{finding.recommendation}

          ## Validation

          #{validation_lines.join("\n")}

          ## Diffstat

          ```text
          #{patch.diffstat}
          ```
        MD
      end

      def diff_for(worktree_path)
        # Scan the whole branch against its base, not just the last commit.
        # The PR diff is `default_branch...HEAD`; if the fix agent made more
        # than one commit, a `HEAD~1..HEAD` scan would let earlier commits
        # bypass the secret gate (R5) even though they ship in the PR. Mirror
        # the range Fixer#committed_since_base? already uses.
        out, = @gh.capture3("git", "-C", worktree_path, "diff", "#{default_branch}...HEAD", cfg: @cfg)
        out
      rescue Hive::GhError
        ""
      end

      def record_mapping(finding, patch, pr_url, state, now)
        fingerprints = @state.fingerprints
        Fingerprint.record_seen(
          fingerprints,
          finding.fingerprint,
          branch: patch.branch,
          pr_url: pr_url,
          state: state,
          finding: finding,
          now: now
        )
        @state.write_fingerprints(fingerprints)
      end
    end
  end
end
