require "tempfile"
require "time"
require "hive/gh"
require "hive/git_ops"
require "hive/patrol/effect_gateway"
require "hive/patrol/fingerprint"
require "hive/patrol/review_handoff"
require "hive/patrol/state_store"
require "hive/secret_patterns"
require "hive/worktree"

module Hive
  module Patrol
    class PrOpener
      RESULT_STATUSES = %i[blocked error opened opened_review_handoff_failed skipped].freeze
      RESULT_REASONS = [
        nil, "existing_pr", "gh_error", "review_handoff_failed",
        "secret_detected", "validation_failed"
      ].freeze

      Result = Struct.new(:status, :pr_url, :reason, :detail, :review_task_path, keyword_init: true) do
        def initialize(**attributes)
          super
          unless PrOpener::RESULT_STATUSES.include?(status)
            raise ArgumentError, "unknown patrol PR result status: #{status.inspect}"
          end
          unless PrOpener::RESULT_REASONS.include?(reason)
            raise ArgumentError, "unknown patrol PR result reason: #{reason.inspect}"
          end
        end

        def opened?
          %i[opened opened_review_handoff_failed].include?(status)
        end

        def review_handoff_failed?
          status == :opened_review_handoff_failed || reason == "review_handoff_failed"
        end
      end

      def initialize(project_root, cfg:, state:, capture:, gh: Hive::Gh,
                     review_handoff: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @gh = gh
        @review_handoff = review_handoff || ReviewHandoff.new(@project_root, cfg: cfg, state: state)
        @capture = capture
      end

      def open(finding, patch, now: Time.now)
        @state.with_cycle_lock do
          open_locked(finding, patch, now: now)
        end
      end

      def open_locked(finding, patch, now:)
        return Result.new(status: :skipped, reason: "validation_failed") unless patch.passed

        assert_local_patch_identity!(patch)
        gateway = effect_gateway
        @state.recover_pending_fingerprint_effects!
        pending = reconciliation_pending_entry(finding, patch)

        # Authenticate first: `lookup_prs_for_branch` shells out to `gh`
        # and raises GhError on an unauthenticated host, which surfaces a
        # less actionable error than the explicit auth check and (before
        # this) escaped unrescued — aborting the whole cycle after a fix
        # was already validated and its worktree created.
        @gh.ensure_authenticated!(@cfg)

        branch_prs = @gh.lookup_prs_for_branch(patch.worktree_path, patch.branch)
        existing = branch_prs.find do |pr|
          %w[OPEN MERGED].include?(pr["state"]) &&
            (!pending || pr["url"].to_s == pending["pr_url"].to_s)
        end
        if pending && !existing
          raise Hive::GhError,
                "created patrol PR #{pending['pr_url']} could not be reconciled"
        end
        if existing
          handoff_open_pr = review_prs_enabled? && existing["state"] == "OPEN"
          assert_existing_pr_identity!(
            existing,
            patch,
            require_base_oid: !pending.nil? || handoff_open_pr
          )
          unless pending
            reconciliation = reconcile_pull_request_effect!(
              gateway, finding, patch, observed_prs: branch_prs
            )
            drain_publication!(reconciliation)
            pending = reconciliation_pending_entry(finding, patch)
          end
          if review_prs_enabled? && existing["state"] == "OPEN"
            assert_local_patch_identity!(patch)
            assert_remote_patch_identity!(patch)
            review_task_path = enqueue_review_task(
              gateway, finding, patch, existing["url"], now
            )
            unless review_task_path
              # Preserve the exact validated worktree. Fixer reuses its
              # durable patch receipt on the next cycle, allowing handoff
              # recovery without rebuilding a different commit.
              record_mapping(
                finding, patch, existing["url"],
                "review_handoff_failed", now
              )
              return Result.new(
                status: :skipped,
                pr_url: existing["url"],
                reason: "review_handoff_failed"
              )
            end

            record_mapping(
              finding, patch, existing["url"],
              existing["state"].downcase, now
            )
            return Result.new(
              status: :skipped,
              pr_url: existing["url"],
              reason: "existing_pr",
              review_task_path: review_task_path
            )
          end

          record_mapping(
            finding, patch, existing["url"],
            existing["state"].downcase, now
          )
          # The branch already has a PR; this validated worktree is now
          # dead weight. Remove it so `.patrol/` doesn't accumulate one
          # leaked checkout per cycle.
          cleanup_worktree(patch)
          return Result.new(status: :skipped, pr_url: existing["url"], reason: "existing_pr")
        end

        assert_remote_base_identity!(patch)
        title = title_for(finding)
        body = body_for(finding, patch)
        secret_hits = Hive::SecretPatterns.scan(title) +
                      Hive::SecretPatterns.scan(body) +
                      Hive::SecretPatterns.scan(diff_for(patch))
        if secret_hits.any?
          # The diff that tripped the secret gate may contain credentials;
          # don't leave it on disk under the patrol worktree root.
          cleanup_worktree(patch)
          return Result.new(status: :blocked, reason: "secret_detected")
        end

        assert_local_patch_identity!(patch)
        perform_branch_effect!(gateway, finding, patch)
        assert_local_patch_identity!(patch)
        assert_remote_patch_identity!(patch)
        assert_remote_base_identity!(patch)
        publication = perform_pull_request_effect!(
          gateway, finding, patch, body, observed_prs: branch_prs
        )
        pr_url = publication.outcome.fetch("pr_url")
        drain_publication!(publication)
        reconciliation_pending_entry(finding, patch)
        assert_local_patch_identity!(patch)
        assert_remote_patch_identity!(patch)
        review_task_path = if review_prs_enabled?
          enqueue_review_task(gateway, finding, patch, pr_url, now)
        end
        if !review_task_path && review_prs_enabled?
          # Preserve the exact validated worktree and patch receipt so the
          # next cycle can retry only the failed review handoff. Rebuilding
          # from a newer base would produce a different commit than the PR.
          record_mapping(
            finding, patch, pr_url, "review_handoff_failed", now
          )
          return Result.new(
            status: :opened_review_handoff_failed,
            pr_url: pr_url,
            reason: "review_handoff_failed"
          )
        end
        record_mapping(finding, patch, pr_url, "open", now)
        if !review_task_path && !review_prs_enabled?
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
        cleanup_worktree(patch) unless
          retain_publication_worktree?(finding, patch)
        Result.new(status: :error, reason: "gh_error", detail: e.message)
      end
      private :open_locked

      private

      def cleanup_worktree(patch)
        return unless patch.worktree_path

        Hive::Worktree.new(@project_root, "patrol-cleanup").remove!(path: patch.worktree_path, force: true)
      rescue StandardError
        nil
      end

      def enqueue_review_task(gateway, finding, patch, pr_url, now)
        # This is the last guard before the task folder is published. Hosted
        # PR reconciliation alone is not enough: the default branch may move
        # after that lookup, and a handoff retry must never enqueue an old-base
        # patrol branch.
        assert_local_patch_identity!(patch)
        assert_remote_patch_identity!(patch)
        assert_remote_base_identity!(patch)
        result = perform_effect do
          gateway.perform!(
            sink: "review_handoff",
            target: pr_url,
            idempotency_key: "#{finding.fingerprint}:#{patch.id}:review_handoff",
            capability: "review_handoff",
            scope: effect_scope(finding, patch),
            reconcile: lambda do |_intent|
              if @review_handoff.respond_to?(:reconcile)
                @review_handoff.reconcile(
                  finding: finding, patch: patch, pr_url: pr_url
                )
              else
                { "status" => "absent", "outcome" => {} }
              end
            end
          ) do
            task_path = @review_handoff.enqueue(
              finding: finding, patch: patch, pr_url: pr_url, now: now
            )
            raise Hive::ConfigError, "patrol review handoff was not published" unless task_path

            { "task_path" => task_path }
          end
        end
        result.outcome.fetch("task_path")
      rescue Hive::GhError
        raise
      rescue StandardError => e
        warn "hive: patrol opened #{pr_url} but failed to enqueue 6-review task: #{e.class}: #{e.message}"
        nil
      end

      def review_prs_enabled?
        @cfg.dig("patrol", "review_prs") != false
      end

      def default_branch
        @cfg["default_branch"] || Hive::GitOps.new(@project_root).detect_default_branch
      end

      def assert_local_patch_identity!(patch)
        expected_head = validated_oid!(patch.head_sha, "validated patch head")
        validated_oid!(patch.base_sha, "validated patch base")
        observed_head = git_output!(patch.worktree_path, "rev-parse", "HEAD").strip
        unless observed_head == expected_head
          raise Hive::GhError,
                "validated patch head changed before publication: " \
                "expected #{expected_head}, observed #{observed_head.inspect}"
        end

        status = git_output!(
          patch.worktree_path, "status", "--porcelain=v1", "--untracked-files=all"
        )
        return if status.empty?

        raise Hive::GhError, "validated patch worktree is dirty before publication"
      end

      def assert_existing_pr_identity!(pr, patch, require_base_oid: false)
        expected = {
          "headRefOid" => validated_oid!(patch.head_sha, "validated patch head"),
          "baseRefName" => default_branch
        }
        if require_base_oid
          expected["baseRefOid"] = validated_oid!(patch.base_sha, "validated patch base")
        end
        mismatches = expected.filter_map do |field, value|
          "#{field}=#{pr[field].inspect}, expected #{value.inspect}" unless pr[field] == value
        end
        return if mismatches.empty?

        label = pr["url"].to_s.empty? ? "" : " (#{pr['url']})"
        raise Hive::GhError, "existing PR identity mismatch#{label}: #{mismatches.join('; ')}"
      end

      def assert_remote_patch_identity!(patch)
        expected = validated_oid!(patch.head_sha, "validated patch head")
        observed = @gh.remote_branch_oid(patch.worktree_path, patch.branch, cfg: @cfg)
        return if observed == expected

        raise Hive::GhError,
              "remote patrol branch identity mismatch: expected #{expected}, observed #{observed.inspect}"
      end

      def assert_remote_base_identity!(patch)
        expected = validated_oid!(patch.base_sha, "validated patch base")
        observed = @gh.remote_branch_oid(patch.worktree_path, default_branch, cfg: @cfg)
        return if observed == expected

        raise Hive::GhError,
              "remote patrol base identity mismatch: expected #{expected}, observed #{observed.inspect}"
      end

      def validated_oid!(value, label)
        oid = value.to_s.strip.downcase
        return oid if oid.match?(/\A[0-9a-f]{40,64}\z/)

        raise Hive::GhError, "#{label} is not a full Git object id"
      end

      def git_output!(worktree_path, *args)
        out, err, status = @gh.capture3(
          "git", "-C", worktree_path, *args, cfg: @cfg
        )
        return out if status.success?

        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise Hive::GhError, "git #{args.join(' ')} failed before patrol publication: #{detail}"
      end

      def create_pr(patch, body)
        Tempfile.create([ "hive-patrol-pr-", ".md" ]) do |file|
          file.write(body)
          file.flush
          args = [ "gh", "pr", "create", "--title", title_for(patch.finding),
                   "--body-file", file.path, "--head", patch.branch, "--base", default_branch ]
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
        proof_section = fix_proof_section(patch.validation["fix_proof"])

        <<~MD
          ## Hive Patrol Finding

          Slice: `#{finding.feature_id}`
          Category: `#{finding.category}`
          Severity: `#{finding.severity}`
          Confidence: `#{finding.confidence}`
          Alpha: `#{finding.alpha_score}`
          Scope: `#{finding.scope}`
          Fingerprint: `#{finding.fingerprint}`

          #{finding.description}

          ## Contract and impact

          **Contract:** #{finding.contract}

          **Impact:** #{finding.impact}

          ## Root cause

          #{finding.root_cause}

          ## Reproduction

          #{finding.reproduction}

          ## Evidence

          #{evidence_lines.join("\n")}

          ## Applied Fix

          #{finding.recommendation}

          **Targeted validation:** #{finding.validation}

          #{proof_section}

          ## Validation

          #{validation_lines.join("\n")}

          ## Diffstat

          ```text
          #{patch.diffstat}
          ```
        MD
      end

      def diff_for(patch)
        # Scan the exact tree transition that Fixer validated. Moving branch
        # names can advance or be rewritten between validation and publication;
        # binding both endpoints prevents an earlier commit from escaping the
        # secret gate or an unrelated default-branch move from changing scope.
        base = validated_oid!(patch.base_sha, "validated patch base")
        head = validated_oid!(patch.head_sha, "validated patch head")
        out, err, status = @gh.capture3(
          "git", "-C", patch.worktree_path, "diff", "#{base}..#{head}", cfg: @cfg
        )
        unless status.success?
          raise Hive::GhError, "git diff for secret scan failed: #{err.strip.empty? ? out : err}"
        end

        out
      end

      def fix_proof_section(proof)
        return "" unless proof.is_a?(Hash)

        audited = Array(proof["audited_paths"]).map { |path| "- `#{path}`" }
        <<~MD.strip
          ## Observed fix proof

          **Agent-reported root cause:** #{proof["root_cause"]}

          **Audited paths:**
          #{audited.join("\n")}

          **Targeted command:** `#{proof["configured_command"]}`

          **Before:** #{proof_result_summary(proof["before"])}

          **After:** #{proof_result_summary(proof["after"])}
        MD
      end

      def proof_result_summary(value)
        return value.to_s unless value.is_a?(Hash)

        "exit=#{value['exit_code']} timed_out=#{value['timed_out'] == true}"
      end

      def record_mapping(finding, patch, pr_url, state, now)
        fingerprint = finding.fingerprint
        current = @state.fingerprints[fingerprint]
        projected = {
          fingerprint =>
            current.is_a?(Hash) ?
              JSON.parse(JSON.generate(current)) : {}
        }
        Fingerprint.record_seen(
          projected,
          fingerprint,
          branch: patch.branch,
          pr_url: pr_url,
          state: state,
          finding: finding,
          now: now
        )
        expected = projected.fetch(fingerprint)
        perform_effect do
          @state.mutate_fingerprints!(
            fingerprint: fingerprint,
            idempotency_key:
              "#{fingerprint}:#{patch.id}:" \
              "fingerprint-publication:#{state}",
            capability: "filesystem_write",
            scope: effect_scope(finding, patch),
            set: expected,
            deleted: [],
            replace: true
          )
        end
      end

      def effect_gateway
        @state.configured_effect_gateway!(capture: @capture)
      end

      def perform_branch_effect!(gateway, finding, patch)
        desired_oid = validated_oid!(patch.head_sha, "validated patch head")
        target = "#{effect_repository(gateway)}:#{patch.branch}"
        perform_effect do
          gateway.perform!(
            sink: "branch",
            target: target,
            idempotency_key: "#{finding.fingerprint}:#{patch.id}:branch",
            capability: "repository_write",
            scope: effect_scope(finding, patch),
            reconcile: lambda do |_intent|
              observed = @gh.remote_branch_oid(
                patch.worktree_path, patch.branch, cfg: @cfg
              )
              if observed == desired_oid
                {
                  "status" => "matched",
                  "outcome" => { "remote_oid" => observed }
                }
              else
                {
                  "status" => "absent",
                  "outcome" => { "observed_oid" => observed }
                }
              end
            end
          ) do
            expected_remote_oid = @gh.remote_branch_oid(
              patch.worktree_path, patch.branch, cfg: @cfg
            )
            @gh.push_branch!(
              patch.worktree_path,
              patch.branch,
              cfg: @cfg,
              expected_remote_oid: expected_remote_oid,
              expected_remote_absent: expected_remote_oid.nil?
            )
            { "remote_oid" => desired_oid }
          end
        end
      end

      def perform_pull_request_effect!(gateway, finding, patch, body, observed_prs:)
        result = perform_effect do
          gateway.perform!(
            sink: "pull_request",
            target: "#{effect_repository(gateway)}:#{patch.branch}",
            idempotency_key: "#{finding.fingerprint}:#{patch.id}:pull_request",
            capability: "github_pull_requests",
            scope: publication_scope(finding, patch, gateway),
            reconcile: lambda do |_intent|
              pull_request_reconciliation(patch, observed_prs: observed_prs)
            end
          ) do
            created_url = create_pr(patch, body)
            reconciliation = pull_request_reconciliation(patch)
            unless reconciliation.fetch("status") == "matched" &&
                   reconciliation.dig("outcome", "pr_url") ==
                     created_url
              raise Hive::GhError,
                    "created patrol PR #{created_url} could not be reconciled"
            end
            reconciliation.fetch("outcome")
          end
        end
        result
      end

      def reconcile_pull_request_effect!(gateway, finding, patch, observed_prs:)
        perform_effect do
          gateway.reconcile!(
            sink: "pull_request",
            target: "#{effect_repository(gateway)}:#{patch.branch}",
            idempotency_key: "#{finding.fingerprint}:#{patch.id}:pull_request",
            capability: "github_pull_requests",
            scope: publication_scope(finding, patch, gateway)
          ) do |_intent|
              pull_request_reconciliation(patch, observed_prs: observed_prs)
          end
        end
      end

      def pull_request_reconciliation(patch, observed_prs: nil)
        candidates = observed_prs || @gh.lookup_prs_for_branch(
          patch.worktree_path, patch.branch
        )
        matches = candidates.select do |pr|
          %w[OPEN MERGED].include?(pr["state"]) &&
            exact_pr_identity?(pr, patch)
        end
        return { "status" => "absent", "outcome" => {} } if matches.empty?
        return { "status" => "ambiguous", "outcome" => {} } unless matches.one?

        pr = matches.fetch(0)
        {
          "status" => "matched",
          "outcome" => {
            "pr_url" => pr.fetch("url"),
            "state" => pr.fetch("state"),
            "head_oid" => pr.fetch("headRefOid"),
            "base_oid" => pr.fetch("baseRefOid")
          }
        }
      end

      def exact_pr_identity?(pr, patch)
        pr["headRefOid"] == validated_oid!(patch.head_sha, "validated patch head") &&
          pr["baseRefOid"] == validated_oid!(patch.base_sha, "validated patch base") &&
          pr["baseRefName"] == default_branch
      end

      def effect_repository(_gateway)
        repository =
          @capture&.project&.fetch("repository", nil).to_s
        if repository.empty?
          raise Hive::GhError,
                "patrol PR publication requires an exact repository identity"
        end
        repository
      end

      def effect_scope(finding, patch)
        patch_identity_for(patch).merge(
          "fingerprint" => finding.fingerprint,
          "branch" => patch.branch
        )
      end

      def publication_scope(finding, patch, gateway)
        effect_scope(finding, patch).merge(
          "repository" => effect_repository(gateway),
          "base_branch" => default_branch,
          "finding_projection" =>
            Hive::Modules::Migration::PatrolEvidence.canonical(
              "category" => finding.category.to_s,
              "feature_id" => finding.feature_id.to_s,
              "target_sha" => finding.target_sha.to_s,
              "title_tokens" => Fingerprint.title_tokens(finding),
              "root_cause_tokens" =>
                Fingerprint.semantic_tokens(finding)
            )
        )
      end

      def perform_effect
        yield
      rescue Hive::Patrol::EffectGateway::Denied,
             Hive::Patrol::EffectGateway::ReconciliationRequired => e
        raise Hive::GhError, e.message
      end

      def reconciliation_pending_entry(finding, patch)
        entry = @state.fingerprints[finding.fingerprint]
        return unless entry.is_a?(Hash) && entry["state"] == "reconciliation_pending"

        binding = entry["publication_binding"]
        unless binding.is_a?(Hash)
          raise Hive::GhError,
                "pending patrol PR is missing its publication binding"
        end

        expected = patch_identity_for(patch).merge(
          "repository" => effect_repository(nil),
          "branch" => patch.branch,
          "base_branch" => default_branch
        )
        mismatches = expected.filter_map do |field, value|
          "#{field}=#{binding[field].inspect}, expected #{value.inspect}" unless binding[field] == value
        end
        unless mismatches.empty?
          raise Hive::GhError,
                "pending patrol PR publication binding mismatch: #{mismatches.join('; ')}"
        end
        unless binding.keys.sort ==
                 StateStore::PUBLICATION_BINDING_KEYS.sort &&
               binding["receipt_id"].to_s.match?(
                 /\Areceipt-[0-9a-f]{64}\z/
               ) &&
               binding["intent_id"].to_s.match?(
                 /\Aintent-[0-9a-f]{64}\z/
               ) &&
               binding["occurrence_id"].to_s.match?(
                 /\Aocc-[0-9a-f]{64}\z/
               )
          raise Hive::GhError,
                "pending patrol PR publication binding is malformed"
        end
        if entry["branch"] != binding["branch"] ||
           entry["pr_url"] != binding["pr_url"] ||
           entry["pr_url"].to_s.empty?
          raise Hive::GhError, "pending patrol PR is missing its exact branch or URL identity"
        end

        entry
      end

      def patch_identity_for(patch)
        {
          "patch_id" => patch.id,
          "worktree_path" => patch.worktree_path,
          "base_sha" => validated_oid!(patch.base_sha, "validated patch base"),
          "head_sha" => validated_oid!(patch.head_sha, "validated patch head")
        }
      end

      def drain_publication!(result)
        receipt = result.receipt
        @state.drain_publication_outbox!(
          receipt.intent.occurrence_id
        )
      rescue Hive::ConfigError => error
        raise Hive::GhError,
              "patrol PR publication projection failed: #{error.message}"
      end

      def retain_publication_worktree?(finding, patch)
        entry = @state.fingerprints[finding.fingerprint]
        if entry.is_a?(Hash) &&
           Fingerprint::RETRYABLE_PUBLICATION_STATES.include?(
             entry["state"]
           )
          return true
        end

        record = @state.occurrence(@capture.occurrence_id)
        return false unless record.is_a?(Hash)

        expected_scope = publication_scope(
          finding, patch, effect_gateway
        )
        cell = record.fetch("effects").values.find do |candidate|
          semantic = candidate["semantic"]
          semantic.is_a?(Hash) &&
            semantic["sink"] == "pull_request" &&
            semantic["scope"] == expected_scope
        end
        return false unless cell
        return true if %w[prepared dispatch_uncertain].include?(
          cell["state"]
        )
        return false unless %w[committed reconciled].include?(
          cell["state"]
        )

        terminal_id = cell["terminal_receipt_id"]
        publication_pending = record.fetch("outbox").any? do |entry|
          entry["kind"] == "publication" &&
            entry["id"] == terminal_id &&
            entry["acknowledged"] == false
        end
        return true if publication_pending

        entry = @state.fingerprints[finding.fingerprint]
        binding = entry.is_a?(Hash) &&
          entry["publication_binding"]
        return true unless binding.is_a?(Hash)

        expected = @state.publication_binding_for_receipt(
          terminal_id, occurrence_id: @capture.occurrence_id
        )
        return true unless patch_identity_for(patch).all? do |field, value|
          expected[field] == value
        end

        binding != expected
      rescue StandardError
        true
      end
    end
  end
end
