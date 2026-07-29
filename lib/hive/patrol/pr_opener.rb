require "tempfile"
require "time"
require "digest"
require "hive/gh"
require "hive/git_ops"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/patrol/effect_gateway"
require "hive/patrol/decision_projection"
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

      def initialize(project_root, cfg:, state: StateStore.new(project_root), gh: Hive::Gh,
                     review_handoff: nil, capture: nil, effect_gateway_factory: nil,
                     evidence_store: nil, config_loader: nil,
                     capability_checker: nil, module_execution: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @gh = gh
        @review_handoff = review_handoff || ReviewHandoff.new(@project_root, cfg: cfg, state: state)
        @capture = capture
        @effect_gateway_factory = effect_gateway_factory
        @evidence_store = evidence_store || Hive::Modules::Migration::EvidenceStore.new(
          root: File.join(
            @project_root, ".hive-state", "module-runtime", "migration",
            "patrol-evidence"
          )
        )
        @config_loader = config_loader || default_config_loader
        @capability_checker = capability_checker || ->(**) { true }
        @module_execution = module_execution
      end

      def open(finding, patch, now: Time.now)
        preserve_worktree = false
        return Result.new(status: :skipped, reason: "validation_failed") unless patch.passed

        assert_local_patch_identity!(patch)
        capture = effect_capture(finding, patch)
        gateway = effect_gateway(finding, patch, capture)
        pending = reconciliation_pending_entry(finding, patch)
        preserve_worktree = !pending.nil?

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
          reconcile_pull_request_effect!(
            gateway, finding, patch, observed_prs: branch_prs
          )
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
              record_mapping(finding, patch, existing["url"], "review_handoff_failed", now)
              return Result.new(
                status: :skipped,
                pr_url: existing["url"],
                reason: "review_handoff_failed"
              )
            end

            record_mapping(finding, patch, existing["url"], existing["state"].downcase, now)
            return Result.new(
              status: :skipped,
              pr_url: existing["url"],
              reason: "existing_pr",
              review_task_path: review_task_path
            )
          end

          record_mapping(finding, patch, existing["url"], existing["state"].downcase, now)
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
        pr_url = perform_pull_request_effect!(
          gateway, finding, patch, body, observed_prs: branch_prs
        )
        # The PR now exists on the remote, but it is not active until exact
        # identity reconciliation and mandatory review handoff settle. Keep
        # the validated patch receipt retryable across read-after-write lag.
        record_mapping(finding, patch, pr_url, "reconciliation_pending", now)
        preserve_worktree = true
        assert_local_patch_identity!(patch)
        assert_remote_patch_identity!(patch)
        created_pr = @gh.lookup_prs_for_branch(patch.worktree_path, patch.branch).find do |pr|
          pr["url"] == pr_url
        end
        raise Hive::GhError, "created patrol PR #{pr_url} could not be reconciled" unless created_pr

        assert_existing_pr_identity!(created_pr, patch, require_base_oid: true)
        review_task_path = if review_prs_enabled?
          enqueue_review_task(gateway, finding, patch, pr_url, now)
        end
        if !review_task_path && review_prs_enabled?
          # Preserve the exact validated worktree and patch receipt so the
          # next cycle can retry only the failed review handoff. Rebuilding
          # from a newer base would produce a different commit than the PR.
          record_mapping(finding, patch, pr_url, "review_handoff_failed", now)
          return Result.new(
            status: :opened_review_handoff_failed,
            pr_url: pr_url,
            reason: "review_handoff_failed"
          )
        end
        record_mapping(finding, patch, pr_url, "open", now)
        preserve_worktree = false
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
        cleanup_worktree(patch) unless preserve_worktree
        Result.new(status: :error, reason: "gh_error", detail: e.message)
      end

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
        @state.mutate_fingerprints do |fingerprints|
          Fingerprint.record_seen(
            fingerprints,
            finding.fingerprint,
            branch: patch.branch,
            pr_url: pr_url,
            state: state,
            finding: finding,
            now: now
          )
          entry = fingerprints.fetch(finding.fingerprint)
          if state == "reconciliation_pending"
            entry["publication_receipt"] = publication_receipt_for(patch)
          else
            entry.delete("publication_receipt")
          end
        end
      end

      def default_config_loader
        return ->(root) { Hive::Config.load(root) } if @capture

        # Direct library callers historically invoke PrOpener only after
        # Patrol admission. Preserve that narrow test/embedding surface;
        # production commands always pass a reservation capture and reload
        # the project configuration from disk.
        admitted = Hive::Config.deep_merge(
          Hive::Config.deep_dup(@cfg),
          "patrol" => { "enabled" => true }
        )
        ->(_root) { admitted }
      end

      def effect_capture(finding, patch)
        return @capture if @capture

        snapshot = Hive::Modules::Migration::Patrols.ownership_snapshot(
          @project_root, "patrol",
          hive_state_path: File.join(@project_root, ".hive-state")
        )
        owner = snapshot["owner"] == "none" ? "legacy" : snapshot.fetch("owner")
        epoch = snapshot["epoch"].to_i.positive? ? snapshot.fetch("epoch") : 1
        identity = [
          finding.fingerprint, patch.id, patch.branch,
          validated_oid!(patch.head_sha, "validated patch head")
        ].join(":")
        selection_input =
          Hive::Patrol::DecisionProjection.operation_input(
            "validated_patch"
          )
        capture = Hive::Modules::Migration::PatrolCapture.build(
          module_name: "patrol",
          project: {
            "project_id" => "local-#{::Digest::SHA256.hexdigest(@project_root)}",
            "name" => File.basename(@project_root),
            "repository" => nil
          },
          trigger: { "kind" => "direct", "id" => identity },
          reservation: { "kind" => "ordinary", "id" => identity },
          owner: owner,
          owner_epoch: epoch,
          selection_input: selection_input,
          selection:
            Hive::Patrol::DecisionProjection.project(
              selection_input
            ),
          outcome_class: nil,
          outcome: nil,
          occurred_at: Time.at(0).utc,
          recorded_at: Time.at(0).utc
        )
        @state.reserve_occurrence!(capture)
        capture
      end

      def effect_gateway(finding, patch, capture)
        @state.reserve_occurrence!(capture)
        options = {
          project_root: @project_root,
          hive_state_path: File.join(@project_root, ".hive-state"),
          capture: capture,
          authority: capture.owner,
          evidence_store: @evidence_store,
          delivery_store: @state,
          config_loader: @config_loader,
          capability_checker: @capability_checker,
          module_execution: @module_execution
        }
        return @effect_gateway_factory.call(**options) if @effect_gateway_factory

        Hive::Patrol::EffectGateway.new(**options)
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
            scope: effect_scope(finding, patch),
            reconcile: lambda do |_intent|
              pull_request_reconciliation(patch, observed_prs: observed_prs)
            end
          ) do
            { "pr_url" => create_pr(patch, body) }
          end
        end
        result.outcome.fetch("pr_url")
      end

      def reconcile_pull_request_effect!(gateway, finding, patch, observed_prs:)
        perform_effect do
          gateway.reconcile!(
            sink: "pull_request",
            target: "#{effect_repository(gateway)}:#{patch.branch}",
            idempotency_key: "#{finding.fingerprint}:#{patch.id}:pull_request",
            capability: "github_pull_requests",
            scope: effect_scope(finding, patch)
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
        @capture&.project&.fetch("repository", nil) ||
          File.basename(@project_root)
      end

      def effect_scope(finding, patch)
        publication_receipt_for(patch).merge(
          "fingerprint" => finding.fingerprint,
          "branch" => patch.branch
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

        receipt = entry["publication_receipt"]
        unless receipt.is_a?(Hash)
          raise Hive::GhError, "pending patrol PR is missing its publication receipt"
        end

        expected = publication_receipt_for(patch)
        mismatches = expected.filter_map do |field, value|
          "#{field}=#{receipt[field].inspect}, expected #{value.inspect}" unless receipt[field] == value
        end
        unless mismatches.empty?
          raise Hive::GhError,
                "pending patrol PR publication receipt mismatch: #{mismatches.join('; ')}"
        end
        if entry["branch"] != patch.branch || entry["pr_url"].to_s.empty?
          raise Hive::GhError, "pending patrol PR is missing its exact branch or URL identity"
        end

        entry
      end

      def publication_receipt_for(patch)
        {
          "patch_id" => patch.id,
          "worktree_path" => patch.worktree_path,
          "base_sha" => validated_oid!(patch.base_sha, "validated patch base"),
          "head_sha" => validated_oid!(patch.head_sha, "validated patch head")
        }
      end
    end
  end
end
