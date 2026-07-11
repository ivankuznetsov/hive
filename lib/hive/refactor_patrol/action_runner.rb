require "json"
require "digest"
require "pathname"
require "time"
require "hive/lock"
require "hive/refactor_patrol/family_store"
require "hive/refactor_patrol/fixer"
require "hive/refactor_patrol/issue_filer"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/policy"
require "hive/refactor_patrol/pr_opener"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    # Resumes the immutable per-thesis action snapshot for one classified PR
    # job. The runner owns ordering and fencing; effect adapters own only one
    # guarded fix, PR, or issue transition at a time.
    class ActionRunner
      Result = Struct.new(
        :aggregate, :actions, :completeness, :dry_run,
        keyword_init: true
      ) do
        def complete? = completeness.fetch("complete")
        alias complete complete?

        def to_h
          {
            "aggregate" => aggregate,
            "actions" => actions,
            "completeness" => completeness,
            "dry_run" => dry_run
          }
        end
      end

      STRATEGIC_REASONS = IssueFiler::STRATEGIC_REASONS.freeze
      NO_ISSUE_FIX_OUTCOMES = %w[no_diff].freeze
      REMOTE_UNCERTAIN_OUTCOME = "remote_outcome_unknown".freeze

      attr_reader :fixer, :pr_opener, :issue_filer

      def initialize(project_root, cfg:, job_store: nil, family_store: nil,
                     fixer: nil, pr_opener: nil, issue_filer: nil,
                     owner: nil, clock: -> { Time.now }, gate_reader: nil,
                     claim_resolver: nil, lease_sec: 3600, backoff_sec: 60)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @job_store = job_store || JobStore.new(@project_root)
        @family_store = family_store || FamilyStore.new(@project_root, clock: clock)
        @fixer_override = fixer
        @pr_opener_override = pr_opener
        @issue_filer_override = issue_filer
        @fixer = fixer
        @pr_opener = pr_opener
        @issue_filer = issue_filer
        @owner = owner.to_s.empty? ? "refactor-action-#{Process.pid}" : owner.to_s
        @owner_pid = Process.pid
        @owner_process_start_time = Hive::Lock.process_start_time(@owner_pid)
        @clock = clock
        @gate_reader = gate_reader || method(:configured_gates)
        @claim_resolver = claim_resolver
        @lease_sec = lease_sec
        @backoff_sec = backoff_sec
      end

      def run(job_id:, dry_run: false)
        @events = []
        aggregate = @job_store.read_job(job_id)
        return result(aggregate, dry_run: dry_run) if aggregate.fetch("complete")

        prepare_policy(aggregate)
        if @policy_result.error &&
           (aggregate.dig("policy", "auto_fix") == true ||
            aggregate.dig("policy", "issue_filing") == true ||
            aggregate.fetch("actions").any?)
          return result(aggregate, dry_run: dry_run, reason: @policy_result.error)
        end

        if aggregate.fetch("actions").empty?
          if !dry_run && !current_gate("discovery")
            return result(aggregate, dry_run: false, reason: "discovery_revoked")
          end

          specifications, previews, errors = action_snapshot(aggregate, dry_run: dry_run)
          if errors.any?
            return result(
              aggregate,
              actions: errors,
              dry_run: dry_run,
              reason: errors.first.fetch("outcome")
            )
          end
          if dry_run
            return result(
              aggregate,
              actions: previews,
              dry_run: true,
              reason: specifications.empty? ? "would_complete_report_only" : "dry_run_preview",
              would_complete: specifications.empty?
            )
          end

          unless current_gate("discovery")
            return result(aggregate, dry_run: false, reason: "discovery_revoked")
          end

          aggregate = @job_store.initialize_actions!(
            aggregate.fetch("job_id"),
            specifications: specifications,
            now: now
          )
          @events.concat(previews.select { |item| item.fetch("outcome") == "family_ambiguous" })
        end

        if dry_run
          return result(
            aggregate,
            actions: resume_preview(aggregate),
            dry_run: true,
            reason: "dry_run_preview"
          )
        end

        process_actions(aggregate.fetch("job_id")) unless aggregate.fetch("complete")
        result(@job_store.read_job(aggregate.fetch("job_id")), dry_run: false)
      rescue JobStore::StaleClaim => e
        aggregate = @job_store.read_job(job_id)
        @events << event("stale_claim", error: e.message)
        result(aggregate, dry_run: dry_run, reason: "stale_claim")
      end
      alias call run

      private

      def action_snapshot(aggregate, dry_run:)
        entries, errors = reconstruct_entries(aggregate)
        return [ [], [], errors ] if errors.any?

        policy = aggregate.fetch("policy")
        specifications = []
        previews = []
        issue_candidates = issue_candidates(entries, policy)
        resolved = issue_candidates.filter_map do |entry|
          family = resolve_family(aggregate, entry, dry_run: dry_run)
          if family.ambiguous?
            errors << event(
              "family_ambiguous",
              kind: "issue",
              thesis_id: entry.fetch(:thesis).id,
              reason: family.reason
            )
            next
          end

          entry.merge(family_id: family.family_id)
        rescue StandardError => e
          errors << event(
            "family_resolution_failed",
            kind: "issue",
            thesis_id: entry.fetch(:thesis).id,
            error: "#{e.class}: #{e.message}"
          )
          nil
        end
        return [ [], previews, errors ] if errors.any?

        family_by_thesis = resolved.to_h do |entry|
          [ entry.fetch(:thesis).id, entry.fetch(:family_id) ]
        end
        if policy.fetch("auto_fix")
          entries.fetch("accepted").each do |entry|
            specification = { "thesis_id" => entry.fetch(:thesis).id, "kind" => "fix" }
            family_id = family_by_thesis[entry.fetch(:thesis).id]
            specification["family_id"] = family_id if family_id
            specifications << specification
          end
        end

        select_issue_representatives(resolved).each do |entry|
          specifications << {
            "thesis_id" => entry.fetch(:thesis).id,
            "kind" => "issue",
            "family_id" => entry.fetch(:family_id)
          }
        end
        previews.concat(preview_specifications(aggregate, specifications)) if dry_run
        [ specifications, previews, errors ]
      end

      def reconstruct_entries(aggregate)
        errors = []
        entries = JobStore::DISPOSITIONS.to_h do |name|
          reconstructed = aggregate.dig("dispositions", name).filter_map do |item|
            snapshot = item["thesis"]
            unless snapshot.is_a?(Hash)
              errors << event(
                "invalid_thesis_snapshot",
                thesis_id: item["id"],
                disposition: name,
                error: "missing immutable thesis snapshot"
              )
              next
            end

            {
              disposition: name,
              item: item,
              thesis: Thesis.from_h(json_copy(snapshot))
            }
          rescue KeyError, ArgumentError => e
            errors << event(
              "invalid_thesis_snapshot",
              thesis_id: item["id"],
              disposition: name,
              error: e.message
            )
            nil
          end
          [ name, reconstructed ]
        end
        [ entries, errors ]
      end

      def issue_candidates(entries, policy)
        return [] unless policy.fetch("issue_filing")

        flagged = entries.fetch("flagged").select { |entry| strategic_flagged?(entry) }
        accepted = if policy.fetch("auto_fix")
          entries.fetch("accepted")
        else
          []
        end
        flagged + accepted
      end

      def strategic_flagged?(entry)
        thesis = entry.fetch(:thesis)
        return false unless entry.dig(:item, "admissible") == true && thesis.admissible == true

        reasons = Array(entry.dig(:item, "reasons")) + Array(thesis.risk && thesis.risk["flags"])
        (reasons.map(&:to_s) & STRATEGIC_REASONS).any?
      end

      def resolve_family(aggregate, entry, dry_run:)
        item = entry.fetch(:item)
        @family_store.resolve(
          thesis: entry.fetch(:thesis),
          repository: aggregate.dig("source", "repository"),
          job_id: aggregate.fetch("job_id"),
          source: aggregate.fetch("source"),
          hinted_family_id: item["family_id"],
          dry_run: dry_run
        )
      end

      def select_issue_representatives(entries)
        entries.group_by { |entry| entry.fetch(:family_id) }.values.map do |family_entries|
          family_entries.min_by do |entry|
            [ entry.fetch(:disposition) == "flagged" ? 0 : 1, entry.fetch(:thesis).id ]
          end
        end.sort_by { |entry| [ entry.fetch(:family_id), entry.fetch(:thesis).id ] }
      end

      def preview_specifications(aggregate, specifications)
        entries = disposition_index(aggregate)
        specifications.map do |specification|
          item = entries.fetch(specification.fetch("thesis_id")).fetch(:item)
          identity = specification.fetch("kind") == "issue" ? specification.fetch("family_id") : item.fetch("fingerprint")
          {
            "canonical_action_id" => @job_store.canonical_action_id(
              repository: aggregate.dig("source", "repository"),
              kind: specification.fetch("kind"),
              identity: identity
            ),
            "thesis_id" => specification.fetch("thesis_id"),
            "kind" => specification.fetch("kind"),
            "family_id" => specification["family_id"],
            "outcome" => "would_initialize",
            "terminal" => false,
            "authorized" => effect_authorized?(specification.fetch("kind"))
          }.compact
        end
      end

      def resume_preview(aggregate)
        aggregate.fetch("actions").map do |action|
          preview = if action.fetch("terminal")
            "already_terminal"
          elsif action.fetch("owner_job_id") != aggregate.fetch("job_id")
            "would_reconcile"
          elsif effect_authorized?(action.fetch("kind"))
            "would_resume"
          else
            "authority_revoked"
          end
          json_copy(action).merge("preview" => preview)
        end
      end

      def process_actions(job_id)
        action_ids = @job_store.read_job(job_id).fetch("actions").sort_by do |action|
          [ action.fetch("kind") == "fix" ? 0 : 1, action.fetch("canonical_action_id") ]
        end.map { |action| action.fetch("canonical_action_id") }

        action_ids.each do |action_id|
          aggregate = @job_store.read_job(job_id)
          action = aggregate.fetch("actions").find do |candidate|
            candidate.fetch("canonical_action_id") == action_id
          end
          next if action.fetch("terminal")

          if action.fetch("owner_job_id") != aggregate.fetch("job_id")
            @job_store.reconcile_linked_action!(job_id, action_id, now: now)
            next
          end

          process_owner_action(aggregate, action)
        end
      end

      def process_owner_action(aggregate, action)
        entry = disposition_index(aggregate)[action.fetch("thesis_id")]
        unless entry
          @events << event(
            "invalid_thesis_snapshot",
            canonical_action_id: action.fetch("canonical_action_id"),
            thesis_id: action.fetch("thesis_id")
          )
          return
        end

        if action.fetch("kind") == "issue"
          route = issue_route(aggregate, action, entry)
          return if route.fetch(:outcome) == :waiting

          return finish_local_issue(aggregate, action, route.fetch(:outcome)) if route.fetch(:outcome)
        end

        token = claim_action(aggregate, action)
        return unless token

        # The winning claim is the synchronization point. A prior worker may
        # have appended a receipt and released after our pre-claim read, so all
        # effect decisions below must use the post-claim aggregate.
        aggregate = @job_store.read_job(aggregate.fetch("job_id"))
        action = current_action(token)
        entry = disposition_index(aggregate)[action.fetch("thesis_id")]
        unless entry
          release(token, "invalid_thesis_snapshot")
          return
        end

        if token.fetch(:continuation_only) != true && !effect_authorized?(action.fetch("kind"))
          release(token, "authority_revoked")
          return
        end

        if action.fetch("kind") == "fix"
          process_fix(token, aggregate, action, entry.fetch(:thesis))
        else
          process_issue(token, aggregate, action, entry.fetch(:thesis), route.fetch(:reasons))
        end
      rescue JobStore::StaleClaim
        raise
      rescue StandardError => e
        settle_unexpected_failure(aggregate, action, token, e)
      end

      def claim_action(aggregate, action)
        @job_store.claim_action!(
          aggregate.fetch("job_id"),
          action.fetch("canonical_action_id"),
          owner: @owner,
          now: now,
          lease_sec: @lease_sec,
          claim_resolver: @claim_resolver,
          owner_pid: @owner_pid,
          owner_process_start_time: @owner_process_start_time,
          authority: effect_authorized?(action.fetch("kind"))
        )
      end

      def process_fix(token, aggregate, action, thesis)
        patch = patch_from_receipts(action, aggregate, thesis)
        if patch == :invalid
          release(token, "invalid_patch_receipt")
          return
        end
        unless patch
          unless effect_authorized?("fix")
            release(token, "authority_revoked")
            return
          end

          patch = @fixer.attempt(
            thesis: thesis,
            job_id: aggregate.fetch("job_id"),
            analysis_sha: aggregate.fetch("analysis_sha")
          )
          unless valid_fixer_result?(patch)
            release(token, "invalid_fixer_result")
            return
          end
          unless patch.publishable?
            receipts = patch.terminal ? { "fix" => json_copy(patch.to_h) } : {}
            settle(token, patch, receipts: receipts, adapter: :fix)
            return
          end
          unless valid_patch?(patch, aggregate, action, thesis)
            release(token, "invalid_fixer_result")
            return
          end

          @job_store.record_patch_receipt!(
            token,
            receipt: json_copy(patch.to_h),
            now: now
          )
        end

        unless token.fetch(:continuation_only) == true || effect_authorized?("fix")
          release(token, "authority_revoked")
          return
        end

        fresh_action = current_action(token)
        intent = pr_intent(aggregate, action, patch)
        creation_attempted = creation_intent_state(fresh_action, intent)
        if creation_attempted == :invalid
          release(token, "invalid_creation_intent")
          return
        end
        result = @pr_opener.open(
          thesis: thesis,
          patch: patch,
          job_id: aggregate.fetch("job_id"),
          canonical_action_id: action.fetch("canonical_action_id"),
          source: aggregate.fetch("source"),
          record_intent: creation_intent_callback(
            token,
            "fix",
            intent
          ),
          authorize_push: external_effect_fence(token, "fix"),
          creation_attempted: creation_attempted
        )
        if result.is_a?(PrOpener::Result) && result.outcome == "trunk_drift_retry"
          mark_patch_superseded!(token, patch)
        end
        settle(token, result, adapter: :pr)
      end

      def process_issue(token, aggregate, action, thesis, reasons)
        unless token.fetch(:continuation_only) == true || effect_authorized?("issue")
          release(token, "authority_revoked")
          return
        end

        fresh_action = current_action(token)
        intent = issue_intent(aggregate, action)
        creation_attempted = creation_intent_state(fresh_action, intent)
        if creation_attempted == :invalid
          release(token, "invalid_creation_intent")
          return
        end
        result = @issue_filer.publish(
          thesis: thesis,
          family_id: action.fetch("family_id"),
          canonical_action_id: action.fetch("canonical_action_id"),
          job_id: aggregate.fetch("job_id"),
          source: aggregate.fetch("source"),
          reasons: reasons,
          record_intent: creation_intent_callback(
            token,
            "issue",
            intent
          ),
          creation_attempted: creation_attempted
        )
        settle(token, result, adapter: :issue)
      end

      def issue_route(aggregate, action, entry)
        family_id = action["family_id"]
        fixes = aggregate.fetch("actions").select do |candidate|
          next false unless candidate.fetch("kind") == "fix"

          if family_id
            candidate["family_id"] == family_id
          else
            candidate.fetch("thesis_id") == entry.fetch(:thesis).id
          end
        end
        unless fixes.empty?
          return { outcome: :waiting, reasons: [] } if fixes.any? { |fix| !fix.fetch("terminal") }
          successful = fixes.any? do |fix|
            patch_receipt_present?(fix) || NO_ISSUE_FIX_OUTCOMES.include?(fix.fetch("outcome"))
          end
          if successful
            return { outcome: "issue_not_needed", reasons: [] }
          end
        end

        if entry.fetch(:disposition) != "accepted" && fixes.empty?
          return { outcome: nil, reasons: Array(entry.dig(:item, "reasons")) }
        end
        if fixes.empty?
          return { outcome: "issue_not_needed", reasons: [] }
        end

        {
          outcome: nil,
          reasons: (Array(entry.dig(:item, "reasons")) + fixes.map { |fix| fix.fetch("outcome") }).uniq
        }
      end

      def finish_local_issue(aggregate, action, outcome)
        token = claim_action(aggregate, action)
        return unless token
        unless token.fetch(:continuation_only) != true && effect_authorized?("issue")
          release(token, "authority_revoked")
          return
        end

        @job_store.finish_action!(token, outcome: outcome, now: now)
      end

      def settle(token, adapter_result, receipts: nil, adapter:)
        unless valid_adapter_result?(adapter, adapter_result)
          release(token, "invalid_action_result")
          return
        end

        result_receipts = receipts || if adapter_result.respond_to?(:receipts)
                                        adapter_result.receipts
                                      else
                                        {}
                                      end
        result_receipts = json_copy(result_receipts || {})
        if adapter_result.terminal == true
          @job_store.finish_action!(
            token,
            outcome: adapter_result.outcome,
            receipts: result_receipts,
            now: now
          )
        else
          @job_store.release_action!(
            token,
            outcome: adapter_result.outcome,
            receipts: result_receipts,
            now: now,
            backoff_sec: @backoff_sec
          )
        end
      end

      def valid_adapter_result?(adapter, result)
        expected = {
          fix: Fixer::Result,
          pr: PrOpener::Result,
          issue: IssueFiler::Result
        }.fetch(adapter)
        return false unless result.is_a?(expected)
        return false unless [ true, false ].include?(result.terminal)
        return false if result.outcome.to_s.empty?
        return true unless result.terminal

        receipts = result.respond_to?(:receipts) ? result.receipts : nil
        case [ adapter, result.outcome ]
        when [ :pr, "pr_opened" ], [ :pr, "merged" ]
          nonempty?(result.pr_url) && nonempty?(result.review_task_path) &&
            receipts.is_a?(Hash) && receipts["pr_url"] == result.pr_url &&
            receipts["review_task_path"] == result.review_task_path
        when [ :pr, "closed_without_merge" ]
          nonempty?(result.pr_url) && receipts.is_a?(Hash) && receipts["pr_url"] == result.pr_url
        when [ :issue, "issue_created" ], [ :issue, "issue_linked_open" ],
             [ :issue, "issue_closed_suppressed" ]
          nonempty?(result.issue_url) && receipts.is_a?(Hash) && receipts["issue_url"] == result.issue_url
        else
          true
        end
      rescue KeyError
        false
      end

      def valid_fixer_result?(patch)
        patch.is_a?(Fixer::Result) && [ true, false ].include?(patch.terminal) &&
          !patch.outcome.to_s.empty?
      end

      def release(token, outcome)
        @job_store.release_action!(
          token,
          outcome: outcome,
          now: now,
          backoff_sec: @backoff_sec
        )
      end

      def settle_unexpected_failure(aggregate, action, token, error)
        @events << event(
          "action_runner_error",
          canonical_action_id: action.fetch("canonical_action_id"),
          error: "#{error.class}: #{error.message}"
        )
        return unless token

        outcome = if creation_intent?(aggregate.fetch("job_id"), action.fetch("canonical_action_id"))
          REMOTE_UNCERTAIN_OUTCOME
        else
          "action_runner_error"
        end
        release(token, outcome)
      rescue JobStore::StaleClaim
        raise
      end

      def creation_intent_callback(token, kind, payload)
        lambda do
          next false unless effect_authorized?(kind)

          @job_store.record_creation_intent!(token, intent: payload, now: now)
          true
        end
      end

      def external_effect_fence(token, kind)
        lambda do
          next false unless effect_authorized?(kind)

          @job_store.assert_action_claim!(token, now: now)
          true
        end
      end

      def pr_intent(aggregate, action, patch)
        {
          "operation" => "create_pr",
          "canonical_action_id" => action.fetch("canonical_action_id"),
          "repository" => aggregate.dig("source", "repository"),
          "branch" => patch.branch,
          "commit_sha" => patch.commit_sha
        }
      end

      def issue_intent(aggregate, action)
        {
          "operation" => "create_issue",
          "canonical_action_id" => action.fetch("canonical_action_id"),
          "repository" => aggregate.dig("source", "repository"),
          "family_id" => action.fetch("family_id"),
          "thesis_fingerprint" => action.fetch("thesis_fingerprint")
        }
      end

      def patch_from_receipts(action, aggregate, thesis)
        receipts = action.fetch("receipts")
        superseded = receipts.filter_map do |key, value|
          value["commit_sha"] if key.start_with?("patch_superseded_") && value.is_a?(Hash)
        end
        keys = receipts.keys.grep(/\Apatch(?:_\d+)?\z/).sort_by do |key|
          key == "patch" ? 1 : key.delete_prefix("patch_").to_i
        end.reverse
        key = keys.find do |candidate|
          receipt = receipts.fetch(candidate)
          receipt.is_a?(Hash) && !superseded.include?(receipt["commit_sha"])
        end
        return nil unless key

        receipt = receipts.fetch(key)
        expected_keys = Fixer::Result.members.map(&:to_s).sort
        return :invalid unless receipt.keys.sort == expected_keys

        values = Fixer::Result.members.to_h { |member| [ member, receipt[member.to_s] ] }
        patch = Fixer::Result.new(**values)
        valid_patch?(patch, aggregate, action, thesis) ? patch : :invalid
      end

      def valid_patch?(patch, aggregate, action, thesis)
        return false unless valid_fixer_result?(patch) && patch.publishable?
        return false unless patch.branch == expected_fix_branch(aggregate.fetch("job_id"), action.fetch("thesis_fingerprint"))
        return false unless Pathname.new(patch.worktree_path.to_s).absolute?
        return false unless patch.analysis_sha == aggregate.fetch("analysis_sha")
        return false unless valid_oid?(patch.publication_base_sha) && valid_oid?(patch.commit_sha)
        return false unless patch.validation.is_a?(Hash) && patch.validation["passed"] == true
        return false unless patch.changed_paths.is_a?(Array) && patch.changed_paths.any? &&
                            patch.changed_paths == patch.changed_paths.uniq &&
                            patch.changed_paths.all? { |path| nonempty?(path) }
        return false unless patch.diff_lines.is_a?(Integer) && patch.diff_lines.positive?
        return false unless patch.details.is_a?(Hash)

        boundary = Array(thesis.feature_boundary && thesis.feature_boundary["owned_files"]) +
                   Array(thesis.feature_boundary && thesis.feature_boundary["entrypoints"])
        (patch.changed_paths - boundary).empty?
      end

      def expected_fix_branch(job_id, fingerprint)
        job = job_id.to_s.gsub(/[^a-zA-Z0-9_.-]+/, "-")[0, 48]
        token = fingerprint.to_s.gsub(/[^a-zA-Z0-9]+/, "")[0, 16]
        "hive-refactor/#{job}-#{token}"
      end

      def valid_oid?(value)
        value.to_s.match?(/\A[0-9a-f]{40,64}\z/)
      end

      def creation_intent_state(action, expected_payload)
        receipt = action.dig("receipts", "creation_intent")
        return false unless receipt
        return :invalid unless receipt.is_a?(Hash) && receipt.keys.sort == %w[payload recorded_at]
        return :invalid unless receipt.fetch("payload") == expected_payload

        Time.iso8601(receipt.fetch("recorded_at").to_s)
        true
      rescue ArgumentError, KeyError
        :invalid
      end

      def mark_patch_superseded!(token, patch)
        key = "patch_superseded_#{Digest::SHA256.hexdigest(patch.commit_sha.to_s)}"
        @job_store.record_action_receipt!(
          token,
          key: key,
          value: {
            "commit_sha" => patch.commit_sha,
            "publication_base_sha" => patch.publication_base_sha,
            "reason" => "trunk_drift_retry"
          },
          now: now
        )
      end

      def patch_receipt_present?(action)
        action.fetch("receipts").keys.any? { |key| key.match?(/\Apatch(?:_\d+)?\z/) }
      end

      def nonempty?(value)
        value.is_a?(String) && !value.empty?
      end

      def current_action(token)
        action = @job_store.read_job(token.fetch(:job_id)).fetch("actions").find do |candidate|
          candidate.fetch("canonical_action_id") == token.fetch(:canonical_action_id)
        end
        raise JobStore::RecordNotFound, "refactor patrol action disappeared" unless action

        action
      end

      def creation_intent?(job_id, action_id)
        action = @job_store.read_job(job_id).fetch("actions").find do |candidate|
          candidate.fetch("canonical_action_id") == action_id
        end
        action&.dig("receipts", "creation_intent").is_a?(Hash)
      end

      def disposition_index(aggregate)
        aggregate.fetch("dispositions").each_with_object({}) do |(name, items), index|
          items.each do |item|
            snapshot = item["thesis"]
            next unless snapshot.is_a?(Hash)

            index[item.fetch("id")] = {
              disposition: name,
              item: item,
              thesis: Thesis.from_h(json_copy(snapshot))
            }
          end
        end
      end

      def effect_authorized?(kind)
        return false unless @policy_result&.authorized?(kind)

        gates = current_gates
        gates.fetch("discovery") && gates.fetch(kind == "fix" ? "auto_fix" : "issue_filing")
      end

      def prepare_policy(aggregate)
        @policy_result = Policy.intersect(aggregate.fetch("policy"), @cfg)
        effective_cfg = @policy_result.config
        @fixer = @fixer_override || Fixer.new(@project_root, cfg: effective_cfg, clock: @clock)
        @pr_opener = @pr_opener_override || PrOpener.new(@project_root, cfg: effective_cfg)
        @issue_filer = @issue_filer_override || IssueFiler.new(@project_root, cfg: effective_cfg)
      end

      def current_gate(name)
        current_gates.fetch(name)
      end

      def current_gates
        value = @gate_reader.call
        {
          "discovery" => value["discovery"] == true || value[:discovery] == true,
          "auto_fix" => value["auto_fix"] == true || value[:auto_fix] == true,
          "issue_filing" => value["issue_filing"] == true || value[:issue_filing] == true
        }
      end

      def configured_gates
        {
          "discovery" => @cfg.dig("refactor_patrol", "enabled") == true,
          "auto_fix" => @cfg.dig("refactor_patrol", "auto_fix", "enabled") == true,
          "issue_filing" => @cfg.dig("refactor_patrol", "issue_filing", "enabled") == true
        }
      end

      def result(aggregate, actions: nil, dry_run:, reason: nil, would_complete: nil)
        action_records = actions || aggregate.fetch("actions").map { |action| json_copy(action) }
        pending = aggregate.fetch("actions").reject { |action| action.fetch("terminal") }
        uncertain = pending.select do |action|
          action.fetch("outcome").match?(/remote_outcome_unknown|handoff|reconcile|conflict/)
        end
        completeness = {
          "state" => aggregate.fetch("state"),
          "complete" => aggregate.fetch("complete"),
          "terminal_actions" => aggregate.fetch("actions").count { |action| action.fetch("terminal") },
          "pending_actions" => pending.map { |action| action.fetch("canonical_action_id") },
          "uncertain_actions" => uncertain.map { |action| action.fetch("canonical_action_id") }
        }
        completeness["reason"] = reason if reason
        completeness["would_complete"] = would_complete unless would_complete.nil?
        completeness["runner_events"] = json_copy(@events) unless @events.empty?
        Result.new(
          aggregate: json_copy(aggregate),
          actions: action_records,
          completeness: completeness,
          dry_run: dry_run
        )
      end

      def event(outcome, **details)
        { "outcome" => outcome }.merge(details.transform_keys(&:to_s)).compact
      end

      def now
        @clock.call
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
