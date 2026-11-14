require "digest"
require "time"
require "hive/agent_git_gate"
require "hive/git_ops"
require "hive/patrol_fix"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/rework_budget"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/worktree_receipt"
require "hive/secret_scanner"

module Hive
  module PatrolFix
    # Returns a patch that the publication secret policy would refuse to the
    # Fix stage with redacted feedback, instead of parking it at Publish.
    #
    # Two entry points share one decision-receipt shape:
    #
    # - Validate runs the exact publication commit-range scan before any
    #   validation command. A finding becomes a validate-stage decision:
    #   `rework` while the shared ReworkBudget remains, otherwise `blocked`,
    #   which parks the task for the operator.
    # - The operator-attested `workflow.secret_rework` action releases a
    #   current secret block: that validate-stage `blocked` decision (rework),
    #   or a Publish `publication_block`. For a Publish block it re-runs the
    #   publication commit scan under the task lock: findings move the task
    #   through Transition's rework route; a clean range (a stale block, for
    #   example after the operator added an exact-fingerprint exception)
    #   reopens Publish itself through the republish route, and Publish's own
    #   full title/body/commit scan decides again.
    #
    # Findings carry only path, line, and Betterleaks rule ID. Matched
    # values, snippets, fingerprints, and value hashes are never persisted or
    # placed in a prompt, and this module never adds scanner exceptions.
    module SecretRework
      ACTION_ID = "workflow.secret_rework".freeze
      CODE = "secret_detected".freeze
      SCAN_OPERATOR = "controller:secret-scan".freeze
      ACTION_OPERATOR = "operator:secret-rework".freeze
      REPUBLISH_OPERATOR = "operator:secret-republish".freeze
      ROUTES = { "validate" => %w[rework blocked].freeze, "publish" => %w[rework].freeze }.freeze
      STAGE_DIRS = { "validate" => "3-validate", "publish" => "5-publish" }.freeze # not-a-stage-ref: Patrol Fix workflow stages
      FIELDS = %w[
        route rationale evidence blocker_owner head_revision diff_digest
        fix_receipt_id code findings omitted_findings secret_policy_version
      ].freeze
      MAX_FINDINGS = 32
      MAX_PATH_BYTES = 512
      MAX_ID_BYTES = 128
      RULE_ID = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
      CONTROL = /[\u0000-\u001f\u007f]/
      FEEDBACK = [
        "Hive's pre-publication secret scan (the same Betterleaks binary, configuration, and operator",
        "exceptions that pull-request publication uses) flagged credential-like literals in the commits",
        "this fix adds. Each finding lists only its file, line, and rule ID; matched values are never",
        "recorded. Do not add credential-like literals such as passwords, tokens, or keys, including in",
        "tests and fixtures. Reuse the project's existing test constants, factories, or fixture helpers,",
        "or build the value in a scanner-safe way that is not a literal credential. The scan covers every",
        "commit between Base and HEAD, so rewrite the fix commits (amend or squash) so that no commit",
        "introduces a flagged literal; deleting it in a follow-up commit is not enough. Do not add",
        "scanner ignore files, allow comments, or other suppressions; Hive does not honor them."
      ].join(" ").freeze
      ESCALATION_SUMMARY = ("The pre-publication secret scan still finds credential-like literals after " \
                            "the Patrol Fix rework limit; an operator must release another rework or close the task.").freeze

      class InvalidDecision < Hive::Error; end
      class Refused < Hive::Error; end

      module_function

      # The publication commit scan, reduced to redacted path/line/rule rows.
      def scan(worktree:, base_revision:, head_revision:, base_branch:)
        require "hive/github_publication"
        Hive::GithubPublication.commit_secret_findings(
          worktree_path: worktree, base_oid: base_revision,
          head_oid: head_revision, base_branch: base_branch
        ).map { |hit| finding(hit) }.uniq.sort_by { |row| row.values_at("path", "line", "rule_id") }
      end

      # Publication scopes its history scan to this branch; the gate must too.
      def base_branch(task, cfg)
        branch = (cfg || {})["default_branch"].to_s
        branch.empty? ? Hive::GitOps.new(task.project_root).detect_default_branch : branch
      end

      # Validate's gate: nil for a clean commit range, otherwise the durable
      # validate-stage decision. Never runs validation commands.
      def pre_publication_gate!(task, cfg, manifest:, store:, fix:, owner:, max_reworks: nil)
        findings = scan(
          worktree: owner.fetch("worktree"), base_revision: owner.fetch("base_revision"),
          head_revision: fix.dig("payload", "head_revision"), base_branch: base_branch(task, cfg)
        )
        return nil if findings.empty?

        limit = ReworkBudget.limit(cfg, max_reworks)
        route = ReworkBudget.remaining?(store.read_all, limit) ? "rework" : "blocked"
        store.append!(decision(manifest: manifest, stage: "validate", route: route, findings: findings, fix: fix))
      rescue Hive::SecretScanner::Unavailable => e
        raise Hive::StageError, "pre-publication secret scan is unavailable: #{e.message}"
      end

      def decision(manifest:, stage:, route:, findings:, fix:, blocked_receipt_id: nil,
                   recorded_at: Time.now.utc)
        shown = findings.first(MAX_FINDINGS)
        omitted = findings.length - shown.length
        payload = {
          "route" => route, "rationale" => FEEDBACK, "evidence" => evidence(shown, omitted),
          "blocker_owner" => route == "rework" ? "fix_agent" : "operator",
          "head_revision" => fix.dig("payload", "head_revision"),
          "diff_digest" => fix.dig("payload", "diff_digest"),
          "fix_receipt_id" => fix.fetch("receipt_id"), "code" => CODE,
          "findings" => shown, "omitted_findings" => omitted,
          "secret_policy_version" => Hive::SecretScanner::POLICY_VERSION
        }
        payload["blocked_receipt_id"] = blocked_receipt_id if stage == "publish"
        validate_payload!(stage, payload)
        identity = Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "task" => manifest.fetch("task"), "stage" => stage, "payload" => payload
        ))
        {
          "schema" => ReceiptStore::SCHEMA, "schema_version" => ReceiptStore::SCHEMA_VERSION,
          "receipt_id" => "secret-#{identity[0, 24]}", "kind" => "decision", "stage" => stage,
          "task" => manifest.fetch("task"), "evidence_revision" => manifest.fetch("evidence_revision"),
          "recorded_at" => recorded_at.utc.iso8601, "payload" => payload
        }
      end

      def validate_payload!(stage, payload)
        fields = stage == "publish" ? FIELDS + %w[blocked_receipt_id] : FIELDS
        valid = payload.is_a?(Hash) && ROUTES.key?(stage) && payload.keys.sort == fields.sort &&
          ROUTES.fetch(stage).include?(payload["route"]) && payload["code"] == CODE &&
          payload["blocker_owner"] == (payload["route"] == "rework" ? "fix_agent" : "operator") &&
          text?(payload["rationale"], ReceiptStore::MAX_TEXT_BYTES) &&
          list?(payload["evidence"], MAX_FINDINGS + 1) { |line| text?(line, ReceiptStore::MAX_TEXT_BYTES) } &&
          list?(payload["findings"], MAX_FINDINGS) { |row| finding?(row) } &&
          payload["omitted_findings"].is_a?(Integer) && payload["omitted_findings"] >= 0 &&
          payload["head_revision"].to_s.match?(ReceiptStore::REVISION) &&
          payload["diff_digest"].to_s.match?(ReceiptStore::DIGEST) &&
          %w[fix_receipt_id secret_policy_version].all? { |key| text?(payload[key], MAX_ID_BYTES) } &&
          (stage != "publish" || text?(payload["blocked_receipt_id"], MAX_ID_BYTES))
        raise InvalidDecision, "secret rework decision payload is invalid" unless valid

        payload
      end

      def decision?(receipt)
        receipt.is_a?(Hash) && receipt["kind"] == "decision" && ROUTES.key?(receipt["stage"]) &&
          receipt.dig("payload", "code") == CODE
      end

      # Only Validate may apply its own automatic rework; every other release
      # is the operator action.
      def rework_operator(decision)
        automatic = decision["stage"] == "validate" && decision.dig("payload", "route") == "rework"
        automatic ? SCAN_OPERATOR : ACTION_OPERATOR
      end

      def authorizes?(reopen, decision)
        decision?(decision) && reopen["stage"] == decision["stage"] &&
          reopen.dig("payload", "outcome_receipt_id") == decision["receipt_id"] &&
          reopen.dig("payload", "operator") == rework_operator(decision)
      end

      # Validate/publish reopens: the gate or the operator rework carry
      # nothing forward; a republish carries exactly the blocked review.
      def reopen_authorized?(stage, operator, carried)
        if stage == "validate"
          return [ SCAN_OPERATOR, ACTION_OPERATOR ].include?(operator) && carried.empty?
        end

        (operator == ACTION_OPERATOR && carried.empty?) ||
          (operator == REPUBLISH_OPERATOR && carried.length == 1)
      end

      # A republish may reuse only the review approval the released block was
      # bound to: same review receipt, HEAD, and diff, one generation back
      # from the generation that republishes.
      def republish_authority?(block, review, block_generation:)
        block.is_a?(Hash) && block["kind"] == "publication_block" && block["stage"] == "publish" &&
          block.dig("payload", "code") == CODE && block.dig("task", "generation") == block_generation &&
          review.is_a?(Hash) && review["kind"] == "decision" && review["stage"] == "review" &&
          review.dig("payload", "route") == "publish" &&
          block.dig("payload", "review_receipt_id") == review["receipt_id"] &&
          block.dig("payload", "head_revision") == review.dig("payload", "head_revision") &&
          block.dig("payload", "diff_digest") == review.dig("payload", "diff_digest")
      end

      # Publish's approval in a republished generation, or nil when the
      # current generation was not reopened by the republish action.
      def republished_review(receipts, manifest)
        reopen = receipts.find do |row|
          row["kind"] == "reopen" && row["stage"] == "publish" && current?(row, manifest) &&
            row.dig("payload", "operator") == REPUBLISH_OPERATOR
        end
        return nil unless reopen

        by_id = receipts.to_h { |row| [ row.fetch("receipt_id"), row ] }
        block = by_id[reopen.dig("payload", "outcome_receipt_id")]
        review = by_id[reopen.dig("payload", "carried_receipts").first]
        unless republish_authority?(block, review, block_generation: manifest.dig("task", "generation") - 1)
          raise Hive::StageError, "republish authorization does not bind the blocked review approval"
        end
        review
      end

      def finding_count(decision)
        decision.dig("payload", "findings").length + decision.dig("payload", "omitted_findings")
      end

      # Read-only: the current secret block an operator may release, or nil.
      def current_block(task_folder:)
        folder = File.expand_path(task_folder)
        stage_dir = File.basename(File.dirname(folder))
        return nil unless STAGE_DIRS.value?(stage_dir)

        manifest = TaskManifest.new(task_folder: folder).read
        current = ReceiptStore.new(task_folder: folder).read_all.select { |row| current?(row, manifest) }
        if stage_dir == STAGE_DIRS.fetch("validate")
          gate = current.find do |row|
            decision?(row) && row["stage"] == "validate" && row.dig("payload", "route") == "blocked"
          end
          return gate && { "stage" => stage_dir, "receipt" => gate }
        end
        receipt = current.find { |row| row["kind"] == "publication_block" && row["stage"] == "publish" }
        return nil unless receipt&.dig("payload", "code") == CODE

        { "stage" => stage_dir, "receipt" => receipt }
      end

      def observation_token(project:, slug:, block:)
        token_for(project, slug, block.fetch("stage"), block.fetch("receipt"))
      end

      # Operator release. Holds the stable slug lock and the task lock; a
      # replay of an already-applied token returns the recorded outcome.
      def operator_rework!(task, cfg:, project:, observation_token:, worktree_root: nil, transition: nil)
        require "hive/lock"
        require "hive/patrol_fix/stage_transition"
        require "hive/patrol_fix/transition"
        StageTransition.with_lock(task) do
          Hive::Lock.with_task_lock(
            task.folder, slug: task.slug, stage: task.stage_name, create: false,
            acquire_under_commit_lock: task.hive_state_path
          ) do
            transition ||= Transition.new(task, worktree_root: worktree_root)
            recovered = transition.reconcile!
            folder = recovered ? recovered.fetch(:task_folder) : task.folder
            released(folder, project: project, slug: task.slug, token: observation_token) ||
              release!(task, folder, cfg, project, observation_token, transition, worktree_root)
          end
        end
      end

      def release!(task, folder, cfg, project, token, transition, worktree_root)
        unless folder == task.folder
          raise Hive::StaleOperationalObservation,
                "a pending Patrol Fix transition moved the task; run hive status --operational --json"
        end
        block = current_block(task_folder: task.folder)
        raise Refused, "the task has no current Patrol Fix secret_detected block" unless block
        unless secure_compare(observation_token(project: project, slug: task.slug, block: block), token)
          raise Hive::StaleOperationalObservation,
                "the secret block changed; run hive status --operational --json for a fresh token"
        end

        manifest = TaskManifest.new(task_folder: task.folder).read
        receipt = block.fetch("receipt")
        owner = verify_custody!(task, manifest, receipt.dig("payload", "head_revision"), worktree_root)
        decision = receipt["kind"] == "decision" ? receipt : publish_decision(task, cfg, manifest, receipt, owner)
        return republish!(task, receipt, transition) unless decision

        moved = transition.apply_secret_rework!(decision, operator: ACTION_OPERATOR)
        { "status" => "reworked", "generation" => moved.fetch(:generation),
          "findings" => finding_count(decision) }
      end
      private_class_method :release!

      # The blocked range no longer reproduces. Nothing for Fix to correct, so
      # reopen Publish under the block's own review; its full scan decides.
      def republish!(task, block, transition)
        review = ReceiptStore.new(task_folder: task.folder).read_all.find do |row|
          row["receipt_id"] == block.dig("payload", "review_receipt_id")
        end
        raise Refused, "the blocked review approval is unavailable" unless review

        moved = transition.apply_secret_republish!(block, review: review)
        { "status" => "republished", "generation" => moved.fetch(:generation), "findings" => 0 }
      end
      private_class_method :republish!

      def publish_decision(task, cfg, manifest, block, owner)
        store = ReceiptStore.new(task_folder: task.folder)
        receipts = store.read_all
        existing = receipts.find do |row|
          decision?(row) && row["stage"] == "publish" && current?(row, manifest)
        end
        return existing if existing

        fix = receipts.find do |row|
          row["receipt_id"] == block.dig("payload", "fix_receipt_id") && row["kind"] == "fix"
        end
        raise Refused, "the blocked fix receipt is unavailable" unless fix

        findings = scan(
          worktree: owner.fetch("worktree"), base_revision: owner.fetch("base_revision"),
          head_revision: block.dig("payload", "head_revision"), base_branch: base_branch(task, cfg)
        )
        return nil if findings.empty?

        store.append!(decision(
          manifest: manifest, stage: "publish", route: "rework", findings: findings, fix: fix,
          blocked_receipt_id: block.fetch("receipt_id")
        ))
      end
      private_class_method :publish_decision

      def verify_custody!(task, manifest, head_revision, worktree_root)
        custody = WorktreeReceipt.new(
          task_folder: task.folder, project_root: task.project_root, slug: task.slug,
          worktree_root: worktree_root
        )
        owner = custody.read
        custody.validate!(owner)
        unless owner.values_at("generation", "evidence_digest") ==
               [ manifest.dig("task", "generation"), manifest.dig("evidence_revision", "digest") ] &&
               git_read(owner.fetch("worktree"), :head_oid).strip == head_revision &&
               git_read(owner.fetch("worktree"), :status).empty?
          raise Refused, "the blocked worktree changed after the block; inspect it before a rework"
        end
        owner
      rescue WorktreeReceipt::InvalidWorktree => e
        raise Refused, "the blocked worktree custody is invalid: #{e.message}"
      end
      private_class_method :verify_custody!

      def released(task_folder, project:, slug:, token:)
        receipts = ReceiptStore.new(task_folder: task_folder).read_all
        by_id = receipts.to_h { |row| [ row.fetch("receipt_id"), row ] }
        receipts.each do |reopen|
          next unless reopen["kind"] == "reopen"

          source, stage, outcome = released_block(reopen, by_id)
          next unless source && secure_compare(token_for(project, slug, STAGE_DIRS.fetch(stage), source), token)

          return outcome.merge("generation" => reopen.dig("task", "generation"))
        end
        nil
      end
      private_class_method :released

      # The block an operator reopen released, its stage, and the replayed
      # outcome; nil for controller reopens.
      def released_block(reopen, by_id)
        outcome = by_id[reopen.dig("payload", "outcome_receipt_id")]
        case reopen.dig("payload", "operator")
        when REPUBLISH_OPERATOR
          [ outcome, "publish", { "status" => "already_republished", "findings" => 0 } ]
        when ACTION_OPERATOR
          return nil unless decision?(outcome)

          source = outcome["stage"] == "publish" ? by_id[outcome.dig("payload", "blocked_receipt_id")] : outcome
          [ source, outcome["stage"], { "status" => "already_reworked", "findings" => finding_count(outcome) } ]
        end
      end
      private_class_method :released_block

      def token_for(project, slug, stage_dir, receipt)
        Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "action_id" => ACTION_ID, "project" => project.to_s, "slug" => slug.to_s,
          "stage" => stage_dir, "receipt_id" => receipt.fetch("receipt_id"),
          "task" => receipt.fetch("task"), "evidence_revision" => receipt.fetch("evidence_revision"),
          "head_revision" => receipt.dig("payload", "head_revision"),
          "diff_digest" => receipt.dig("payload", "diff_digest")
        ))
      end
      private_class_method :token_for

      def finding(hit)
        path = hit[:path].to_s.scrub("?").gsub(CONTROL, "?")
        path = path.byteslice(0, MAX_PATH_BYTES).scrub("?") if path.bytesize > MAX_PATH_BYTES
        path = "(unknown path)" if path.empty?
        rule = hit[:name].to_s
        line = hit[:line]
        {
          "path" => path, "line" => line.is_a?(Integer) && line >= 0 ? line : 0,
          "rule_id" => rule.match?(RULE_ID) ? rule : "unknown-rule"
        }
      end
      private_class_method :finding

      def finding?(row)
        row.is_a?(Hash) && row.keys.sort == %w[line path rule_id] &&
          text?(row["path"], MAX_PATH_BYTES) && row["line"].is_a?(Integer) && row["line"] >= 0 &&
          row["rule_id"].to_s.match?(RULE_ID)
      end
      private_class_method :finding?

      def evidence(findings, omitted)
        lines = findings.map { |row| "#{row.fetch('path')}:#{row.fetch('line')} rule=#{row.fetch('rule_id')}" }
        lines << "#{omitted} more finding(s) omitted" if omitted.positive?
        lines
      end
      private_class_method :evidence

      def list?(value, max, &valid)
        value.is_a?(Array) && value.length.between?(1, max) && value.all?(&valid)
      end
      private_class_method :list?

      def text?(value, max)
        value.is_a?(String) && !value.empty? && value.bytesize <= max && !value.match?(CONTROL)
      end
      private_class_method :text?

      def current?(receipt, manifest)
        receipt.fetch("task") == manifest.fetch("task") &&
          receipt.fetch("evidence_revision") == manifest.fetch("evidence_revision")
      end
      private_class_method :current?

      def git_read(path, operation)
        result = Hive::AgentGitGate.read(path, operation)
        raise Refused, "the blocked worktree #{operation} is unavailable" unless result.success?

        result.stdout
      end
      private_class_method :git_read

      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
      end
      private_class_method :secure_compare
    end
  end
end
