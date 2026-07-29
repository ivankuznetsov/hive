require "json"
require "digest"
require "pathname"
require "time"
require "uri"
require "hive/gh"
require "hive/lock"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/canonical_action_catalog"
require "hive/refactor_patrol/caps"
require "hive/refactor_patrol/family_store"
require "hive/refactor_patrol/fixer"
require "hive/refactor_patrol/effect_gateway"
require "hive/refactor_patrol/issue_filer"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/policy"
require "hive/refactor_patrol/pr_opener"
require "hive/refactor_patrol/process_group_resolver"
require "hive/refactor_patrol/publication_attempt"
require "hive/refactor_patrol/repository_ownership"
require "hive/refactor_patrol/action_transitions"
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
      ISSUE_SUPPRESSING_FIX_OUTCOMES = %w[no_diff pr_opened merged].freeze
      REMOTE_UNCERTAIN_OUTCOME = "remote_outcome_unknown".freeze
      FIX_RELEASE_EVIDENCE_LIMIT = 2_000
      AUTHORITY_RECHECK_SEC = 3600
      AUTHORITY_RECHECK_REASONS = %w[authority_revoked discovery_revoked].freeze

      attr_reader :fixer, :pr_opener, :issue_filer

      def initialize(project_root, cfg:, hive_state_path: nil, job_store: nil, family_store: nil,
                     fixer: nil, pr_opener: nil, issue_filer: nil,
                     owner: nil, clock: -> { Time.now }, gate_reader: nil,
                     claim_resolver: nil, repository_resolver: nil, config_loader: nil,
                     repository_ownership: nil,
                     canonical_action_catalog: nil,
                     registration: nil, token_budget: nil,
                     effect_gateway_factory: nil, evidence_store: nil,
                     occurrence_id: nil, module_execution: nil,
                     lease_sec: 3600, backoff_sec: 60,
                     authority_backoff_sec: AUTHORITY_RECHECK_SEC)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @hive_state_path = File.expand_path(
          hive_state_path || cfg["hive_state_path"] || ".hive-state",
          @project_root
        )
        @token_budget = token_budget
        @registration = registration.to_s.empty? ? cfg["project_name"].to_s : registration.to_s
        project_entry = begin
          Hive::Config.registered_projects.find do |entry|
            File.expand_path(entry.fetch("path")) == @project_root
          end
        rescue Hive::ConfigError, KeyError, TypeError
          nil
        end
        @job_store = job_store || JobStore.new(
          @project_root,
          hive_state_path: @hive_state_path,
          project: project_entry
        )
        @family_store = family_store || FamilyStore.new(
          @project_root, hive_state_path: @hive_state_path,
          clock: clock, job_store: @job_store
        )
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
        @gate_reader = gate_reader
        managed_config = File.file?(File.join(@hive_state_path, "config.yml"))
        @config_loader = config_loader
        @config_loader ||= if managed_config
          ->(root) { Hive::Config.load(root) }
        else
          ->(_root) { @cfg }
        end
        @claim_resolver = claim_resolver || ProcessGroupResolver.new
        @repository_resolver = repository_resolver || lambda do |root, current_cfg|
          Hive::Gh.repository_identity(root, cfg: current_cfg)
        end
        ownership_registry = managed_config ? -> { Hive::Config.registered_projects } : -> { [] }
        @repository_ownership = repository_ownership || RepositoryOwnership.new(
          registry: ownership_registry,
          config_loader: @config_loader,
          require_registration: managed_config,
          identity_resolver: lambda do |entry, current_cfg|
            @repository_resolver.call(entry.fetch("path"), current_cfg)
          end
        )
        @canonical_action_catalog = canonical_action_catalog
        if @canonical_action_catalog.nil? && managed_config
          @canonical_action_catalog = CanonicalActionCatalog.new(
            registry: ownership_registry,
            job_store_factory: lambda do |root|
              expanded_root = File.expand_path(root)
              next @job_store if expanded_root == @project_root

              entry = ownership_registry.call.find do |candidate|
                File.expand_path(candidate.fetch("path")) == expanded_root
              end
              JobStore.new(
                expanded_root,
                hive_state_path: entry && entry["hive_state_path"],
                project: entry
              )
            end
          )
        end
        @lease_sec = lease_sec
        @backoff_sec = backoff_sec
        @authority_backoff_sec = authority_backoff_sec
        @effect_gateway_factory = effect_gateway_factory
        @expected_occurrence_id = occurrence_id
        @module_execution = module_execution
        @effect_evidence_store = evidence_store ||
                                 Hive::Modules::Migration::EvidenceStore.new(
                                   root: File.join(
                                     @hive_state_path,
                                     "module-runtime", "migration",
                                     "patrol-evidence"
                                   )
                                 )
      end

      def run(job_id:, dry_run: false)
        @events = []
        @action_transitions = nil
        aggregate = @job_store.read_job(job_id)
        @effect_capture = ensure_effect_occurrence(aggregate) unless dry_run
        if @expected_occurrence_id && @effect_capture &&
           @effect_capture.occurrence_id != @expected_occurrence_id
          raise JobStore::InconsistentRecord,
                "architecture patrol action occurrence does not match dispatch"
        end
        @source = aggregate.fetch("source")
        return result(aggregate, dry_run: dry_run) if aggregate.fetch("complete")
        if !dry_run && @owner_process_start_time.to_s.empty?
          aggregate = block_action_phase(aggregate, "process_identity_unavailable")
          return result(aggregate, dry_run: false, reason: "process_identity_unavailable")
        end
        if !dry_run && @job_store.action_phase_backoff_active?(aggregate, now: now)
          return result(aggregate, dry_run: false, reason: "action_backoff")
        end

        prepare_policy(aggregate)
        if @policy_result.error &&
           (aggregate.dig("policy", "auto_fix") == true ||
            aggregate.dig("policy", "issue_filing") == true ||
            aggregate.fetch("actions").any?)
          aggregate = block_action_phase(aggregate, @policy_result.error) unless dry_run
          return result(aggregate, dry_run: dry_run, reason: @policy_result.error)
        end

        if dry_run
          ownership = current_repository_ownership_decision(
            aggregate,
            continuation: continuation_evidence?(aggregate)
          )
          if ownership.blocked? && ownership.reason != "architecture_patrol_disabled"
            return result(aggregate, dry_run: true, reason: ownership.reason)
          end
        elsif (blocked = enforce_repository_authority(aggregate))
          return result(blocked, dry_run: false, reason: @repository_identity_reason)
        end

        if aggregate.fetch("actions").empty?
          unless current_gate("discovery")
            if dry_run
              return result(
                aggregate,
                actions: [],
                dry_run: true,
                reason: "discovery_revoked",
                would_complete: false
              )
            end

            aggregate = block_action_phase(aggregate, "discovery_revoked")
            return result(aggregate, dry_run: false, reason: "discovery_revoked")
          end

          specifications, previews, errors = action_snapshot(aggregate, dry_run: dry_run)
          if errors.any?
            aggregate = block_action_phase(
              aggregate, errors.first.fetch("outcome"), "events" => errors
            ) unless dry_run
            return result(
              aggregate,
              actions: errors,
              dry_run: dry_run,
              reason: errors.first.fetch("outcome")
            )
          end
          planned = @job_store.plan_actions(
            aggregate.fetch("job_id"), specifications: specifications
          )
          terminal_proofs = terminal_proofs_for(
            aggregate,
            planned.map { |item| item.fetch("canonical_action_id") },
            dry_run: dry_run
          )
          previews = previews.map do |preview|
            proof = terminal_proofs[preview.fetch("canonical_action_id")]
            if proof
              preview.merge(
                "outcome" => "would_link_terminal",
                "terminal" => true,
                "linked_outcome" => proof.fetch("outcome")
              )
            else
              preview
            end
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
            aggregate = block_action_phase(aggregate, "discovery_revoked")
            return result(aggregate, dry_run: false, reason: "discovery_revoked")
          end

          aggregate = initialize_actions_transition!(
            aggregate,
            specifications: specifications,
            terminal_proofs: terminal_proofs,
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
        refresh_terminal_catalog
        result(@job_store.read_job(aggregate.fetch("job_id")), dry_run: false)
      rescue JobStore::StaleClaim => e
        aggregate = @job_store.read_job(job_id)
        @events << event("stale_claim", error: e.message)
        result(aggregate, dry_run: dry_run, reason: "stale_claim")
      rescue CanonicalActionCatalog::Error => e
        aggregate = @job_store.read_job(job_id)
        @events << event("canonical_action_proof_unresolved", error: e.message)
        aggregate = block_action_phase(
          aggregate, "canonical_action_proof_unresolved", "error" => e.message
        ) unless dry_run
        result(
          aggregate, dry_run: dry_run,
          reason: "canonical_action_proof_unresolved"
        )
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
        entries = JobStore::DISPOSITIONS.to_h { |name| [ name, [] ] }
        JobStore::DISPOSITIONS.each do |name|
          aggregate.dig("dispositions", name).each do |item|
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

            entry = reconstructed_entry(name, item, snapshot)
            entries.fetch(entry.fetch(:disposition)) << entry
          rescue KeyError, ArgumentError => e
            errors << event(
              "invalid_thesis_snapshot",
              thesis_id: item["id"],
              disposition: name,
              error: e.message
            )
          end
        end
        [ entries, errors ]
      end

      def reconstructed_entry(disposition, item, snapshot)
        disposition = @job_store.effective_disposition(disposition, item)
        thesis = Thesis.from_h(json_copy(snapshot))
        normalized_item = json_copy(item)
        normalized_item["reasons"] = Caps.without_legacy_size_flags(normalized_item["reasons"])
        thesis.risk ||= {}
        thesis.risk["flags"] = Caps.without_legacy_size_flags(thesis.risk["flags"])
        normalized_item["thesis"] = thesis.to_h
        { disposition: disposition, item: normalized_item, thesis: thesis }
      end

      def issue_candidates(entries, policy)
        return [] unless policy.fetch("issue_filing")

        flagged = entries.fetch("flagged").select { |entry| strategic_flagged?(entry) }
        flagged + entries.fetch("accepted")
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
              host: source_identity(aggregate.fetch("source")).fetch("host"),
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
          linked = action.fetch("owner_job_id") != job_id
          continuation = linked || remote_continuation_evidence?(action)
          continuation_priority = continuation || effect_authorized?(action.fetch("kind")) ? 0 : 1
          [ continuation_priority, action.fetch("kind") == "fix" ? 0 : 1,
           action.fetch("canonical_action_id") ]
        end.map { |action| action.fetch("canonical_action_id") }

        action_ids.each do |action_id|
          aggregate = @job_store.read_job(job_id)
          action = aggregate.fetch("actions").find do |candidate|
            candidate.fetch("canonical_action_id") == action_id
          end
          next if action.fetch("terminal")

          if action.fetch("owner_job_id") == aggregate.fetch("job_id") &&
             materialize_terminal_action(aggregate, action)
            next
          end

          if action.fetch("owner_job_id") != aggregate.fetch("job_id")
            next unless @job_store.linked_action_ready?(action)

            reconcile_linked_action_transition!(
              aggregate, action, now: now
            )
            next
          end

          process_owner_action(aggregate, action)
          break if @job_store.action_phase_backoff_active?(
            @job_store.read_job(job_id), now: now
          )
        end
      end

      def process_owner_action(aggregate, action)
        if @repository_identity_drift && !remote_continuation_evidence?(action)
          @events << event(
            "repository_identity_drift",
            canonical_action_id: action.fetch("canonical_action_id"),
            expected_repository: aggregate.dig("source", "repository"),
            current_repository: @current_repository
          )
          block_action_phase(
            aggregate, "repository_identity_drift",
            "canonical_action_id" => action.fetch("canonical_action_id"),
            "expected_repository" => aggregate.dig("source", "repository"),
            "current_repository" => @current_repository
          )
          return
        end

        entry = disposition_index(aggregate)[action.fetch("thesis_id")]
        unless entry
          @events << event(
            "invalid_thesis_snapshot",
            canonical_action_id: action.fetch("canonical_action_id"),
            thesis_id: action.fetch("thesis_id")
          )
          block_action_phase(
            aggregate, "invalid_thesis_snapshot",
            "canonical_action_id" => action.fetch("canonical_action_id")
          )
          return
        end

        if action.fetch("kind") == "issue"
          route = issue_route(aggregate, action, entry)
          return if route.fetch(:outcome) == :waiting

          return finish_local_issue(aggregate, action, route.fetch(:outcome)) if route.fetch(:outcome)
        end

        remote_continuation = remote_continuation_evidence?(action)
        token = claim_action(aggregate, action)
        unless token
          current = @job_store.read_job(aggregate.fetch("job_id"))
          blocked = current.fetch("actions").find do |candidate|
            candidate.fetch("canonical_action_id") == action.fetch("canonical_action_id")
          end
          if blocked&.fetch("outcome") == "authority_revoked"
            block_action_phase(
              current, "authority_revoked",
              "canonical_action_id" => action.fetch("canonical_action_id")
            )
          end
          return
        end

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
          process_issue(
            token, aggregate, action, entry.fetch(:thesis), route.fetch(:reasons),
            remote_continuation: remote_continuation
          )
        end
      rescue JobStore::StaleClaim
        raise
      rescue StandardError => e
        settle_unexpected_failure(aggregate, action, token, e)
      end

      def claim_action(aggregate, action)
        ownership = current_repository_ownership_decision(
          aggregate,
          continuation: remote_continuation_evidence?(action)
        )
        if ownership.blocked? && ownership.reason != "architecture_patrol_disabled"
          @events << event(
            ownership.reason,
            canonical_action_id: action.fetch("canonical_action_id"),
            evidence: ownership.evidence
          )
          block_action_phase(aggregate, ownership.reason, ownership.evidence)
          return nil
        end

        action_transitions.claim(
          aggregate,
          action,
          authority:
            !@repository_identity_drift &&
              effect_authorized?(action.fetch("kind")),
          now: now
        )
      end

      def process_fix(token, aggregate, action, thesis)
        patch = patch_from_receipts(action, aggregate, thesis)
        if patch == :invalid
          release(token, "invalid_patch_receipt")
          return
        end
        unless patch
          unless claim_effect_authorized?(token, "fix")
            release(token, "authority_revoked")
            return
          end

          patch = @fixer.attempt(
            thesis: thesis,
            job_id: aggregate.fetch("job_id"),
            canonical_action_id: action.fetch("canonical_action_id"),
            analysis_sha: aggregate.fetch("analysis_sha")
          )
          unless valid_fixer_result?(patch)
            release(token, "invalid_fixer_result")
            return
          end
          unless patch.publishable?
            receipts = patch.terminal ? { "fix" => json_copy(patch.to_h) } : fix_release_evidence(token, patch)
            settle(token, patch, receipts: receipts, adapter: :fix)
            return
          end
          unless valid_patch?(patch, aggregate, action, thesis)
            release(token, "invalid_fixer_result")
            return
          end

        end

        begin
          record_patch_publication_transition!(
            token, patch: json_copy(patch.to_h), now: now
          )
        rescue JobStore::InconsistentRecord, JobStore::CorruptRecord
          release(token, "invalid_creation_intent")
          return
        end
        attempt_id = publication_attempt_id(patch)

        if (denial = transition_denial_reason(token, "fix", aggregate))
          release(token, denial)
          return
        end

        fresh_action = current_action(token)
        publication = publication_state(fresh_action, aggregate, action, patch: patch)
        if publication == :invalid
          release(token, "invalid_creation_intent")
          return
        end
        result = @pr_opener.open(
          thesis: thesis,
          patch: patch,
          job_id: aggregate.fetch("job_id"),
          canonical_action_id: action.fetch("canonical_action_id"),
          source: aggregate.fetch("source"),
          record_intent: publication_intent_callback(
            token, "fix", aggregate, action, patch, attempt_id: attempt_id
          ),
          authorize_push: external_effect_fence(token, "fix"),
          authorize_create: external_effect_fence(token, "fix"),
          authorize_handoff: continuation_fence(token, aggregate),
          execute_effect: publication_effect_executor(
            token, "fix", aggregate, action, patch, attempt_id: attempt_id
          ),
          execute_handoff: handoff_effect_executor(
            token, "fix", aggregate, action, patch
          ),
          creation_attempted: publication.any?,
          publication_state: publication,
          superseded_patch_commits: superseded_patch_commits(fresh_action)
        )
        if result.is_a?(PrOpener::Result) && result.outcome == "trunk_drift_retry"
          action_transitions.supersede_publication(
            token,
            attempt_id: attempt_id,
            observed_head_sha: result.observed_head_sha,
            now: now
          )
        end
        settle(token, result, adapter: :pr)
      end

      def process_issue(token, aggregate, action, thesis, reasons, remote_continuation: false)
        if (denial = transition_denial_reason(token, "issue", aggregate))
          release(token, denial)
          return
        end

        fresh_action = current_action(token)
        publication = publication_state(fresh_action, aggregate, action)
        if publication == :invalid
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
          record_intent: publication_intent_callback(token, "issue", aggregate, action),
          authorize_create: external_effect_fence(token, "issue"),
          execute_effect: publication_effect_executor(
            token, "issue", aggregate, action
          ),
          creation_attempted: publication.any? || remote_continuation ||
            remote_continuation_evidence?(fresh_action),
          publication_state: publication
        )
        settle(token, result, adapter: :issue)
      end

      def issue_route(aggregate, action, entry)
        if remote_continuation_evidence?(action)
          return { outcome: nil, reasons: Array(entry.dig(:item, "reasons")) }
        end

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
          successful = fixes.any? { |fix| ISSUE_SUPPRESSING_FIX_OUTCOMES.include?(fix.fetch("outcome")) }
          if successful
            return { outcome: "issue_not_needed", reasons: [] }
          end
        end

        if entry.fetch(:disposition) != "accepted" && fixes.empty?
          return { outcome: nil, reasons: Array(entry.dig(:item, "reasons")) }
        end
        if fixes.empty?
          if aggregate.dig("policy", "auto_fix") == false
            return { outcome: nil, reasons: [ "auto_fix_disabled" ] }
          end
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

        settle_action_transition!(
          token, outcome: outcome, receipts: {}, terminal: true
        )
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
        aggregate = settle_action_transition!(
          token,
          outcome: adapter_result.outcome,
          receipts: result_receipts,
          terminal: adapter_result.terminal == true
        )
        aggregate
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
        settle_action_transition!(
          token, outcome: outcome, receipts: {}, terminal: false
        )
      end

      def settle_action_transition!(token, outcome:, receipts:, terminal:)
        action_transitions.settle(
          token,
          outcome: outcome,
          receipts: receipts,
          terminal: terminal,
          backoff_sec: backoff_sec_for(outcome),
          now: now
        )
      end

      def initialize_actions_transition!(aggregate, specifications:,
                                         terminal_proofs:, now:)
        action_transitions.initialize_actions(
          aggregate,
          specifications: specifications,
          terminal_proofs: terminal_proofs,
          now: now
        )
      end

      def reconcile_linked_action_transition!(aggregate, action, now:)
        action_transitions.reconcile_linked(
          aggregate, action, now: now
        )
      end

      def record_patch_publication_transition!(token, patch:, now:)
        action_transitions.record_patch_publication(
          token, patch: patch, now: now
        )
      end

      def record_creation_intent_transition!(token, phase, payload)
        action_transitions.record_creation_intent(
          token, phase, payload, now: now
        )
      end

      def record_action_receipt_transition!(token, phase, payload)
        action_transitions.record_action_receipt(
          token, phase, payload, now: now
        )
      end

      def action_transitions
        @action_transitions ||= Hive::RefactorPatrol::ActionTransitions.new(
          project_root: @project_root,
          hive_state_path: @hive_state_path,
          job_store: @job_store,
          evidence_store: @effect_evidence_store,
          capture: @effect_capture,
          config_loader: @config_loader,
          module_execution: @module_execution,
          clock: @clock,
          owner: @owner,
          owner_pid: @owner_pid,
          owner_process_start_time: @owner_process_start_time,
          lease_sec: @lease_sec,
          claim_resolver: @claim_resolver
        )
      end

      # Receipts are write-once, so a retryable fix failure records its error
      # detail under the claim generation that produced it. Without this the
      # non-terminal error text is dropped and never persists anywhere.
      def fix_release_evidence(token, patch)
        details = patch.details.is_a?(Hash) ? patch.details : {}
        return {} if details.empty?

        {
          "fix_release_#{token.fetch(:generation)}" => {
            "outcome" => patch.outcome,
            "details" => JSON.generate(details)[0, FIX_RELEASE_EVIDENCE_LIMIT]
          }
        }
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

      def publication_intent_callback(token, kind, aggregate, action, patch = nil,
                                      attempt_id: nil)
        lambda do |phase: nil, payload: nil|
          phase ||= kind == "fix" ? PrOpener::PR_CREATE_INTENT : "issue_create_intent"
          payload ||= expected_publication_payload(
            kind, phase, aggregate, action, patch, expected_remote_oid: nil
          )
          expected_oid = payload.is_a?(Hash) ? payload["expected_remote_oid"] : nil
          expected = expected_publication_payload(
            kind, phase, aggregate, action, patch,
            expected_remote_oid: expected_oid
          )
          unless payload == expected
            raise JobStore::InconsistentRecord, "publication intent payload is invalid"
          end
          persist_publication_phase(
            token, kind, phase, payload, attempt_id: attempt_id
          )
          true
        end
      end

      def publication_effect_executor(token, kind, aggregate, action, patch = nil,
                                      attempt_id: nil)
        lambda do |phase:, payload:, &effect|
          expected = expected_publication_payload(
            kind, phase, aggregate, action, patch,
            expected_remote_oid: payload.is_a?(Hash) ?
              payload["expected_remote_oid"] : nil
          )
          unless payload == expected
            raise JobStore::InconsistentRecord,
                  "publication effect payload is invalid"
          end

          capture = effect_capture(token, aggregate, action)
          descriptor = effect_descriptor(
            token, kind, phase, payload, aggregate, action,
            attempt_id: attempt_id
          )
          gateway = build_effect_gateway(
            token,
            kind,
            phase,
            payload,
            capture,
            attempt_id: attempt_id
          )
          persist_publication_phase(
            token, kind, phase, payload, attempt_id: attempt_id
          )
          delivered = false
          delivered_value = nil
          result = gateway.perform!(
            sink: descriptor.fetch(:sink),
            target: descriptor.fetch(:target),
            idempotency_key: descriptor.fetch(:idempotency_key),
            capability: descriptor.fetch(:capability),
            claim_generation: token.fetch(:generation),
            scope: effect_scope(token)
          ) do
            delivered_value = json_copy(effect.call)
            delivered = true
            publication_effect_outcome(
              descriptor.fetch(:sink),
              delivered_value,
              payload
            )
          end
          delivered ? delivered_value :
            publication_effect_value(
              descriptor.fetch(:sink), result.outcome
            )
        end
      end

      def handoff_effect_executor(token, kind, aggregate, action, patch)
        lambda do |phase:, payload:, &effect|
          expected = {
            "pr_url" => payload.is_a?(Hash) ? payload["pr_url"] : nil,
            "job_id" => aggregate.fetch("job_id"),
            "canonical_action_id" => action.fetch("canonical_action_id"),
            "commit_sha" => patch.commit_sha
          }
          unless phase == "review_handoff" &&
                 expected["pr_url"].to_s.match?(%r{\Ahttps://}) &&
                 payload == expected
            raise JobStore::InconsistentRecord,
                  "review handoff effect payload is invalid"
          end

          capture = effect_capture(token, aggregate, action)
          gateway = build_effect_gateway(
            token,
            kind,
            phase,
            payload,
            capture,
            attempt_id: nil,
            persist_publication: false
          )
          result = gateway.perform!(
            sink: "review_handoff",
            target: payload.fetch("pr_url"),
            idempotency_key: [
              token.fetch(:job_id),
              token.fetch(:canonical_action_id),
              "review_handoff",
              payload.fetch("pr_url")
            ].join(":"),
            capability: "review_handoff",
            claim_generation: token.fetch(:generation),
            scope: effect_scope(token)
          ) do
            {
              "task_path" => json_copy(effect.call).to_s
            }
          end
          result.outcome.fetch("task_path")
        end
      end

      def publication_effect_outcome(sink, value, payload)
        case sink
        when "branch"
          { "remote_oid" => payload.fetch("commit_sha").to_s }
        when "pull_request"
          { "pr_url" => value.to_s }
        when "issue"
          { "issue_url" => value.to_s }
        else
          raise JobStore::InconsistentRecord,
                "publication effect sink is unsupported"
        end
      end

      def publication_effect_value(sink, outcome)
        case sink
        when "branch"
          outcome.fetch("remote_oid")
        when "pull_request"
          outcome.fetch("pr_url")
        when "issue"
          outcome.fetch("issue_url")
        else
          raise JobStore::InconsistentRecord,
                "publication effect sink is unsupported"
        end
      rescue KeyError, TypeError
        raise JobStore::InconsistentRecord,
              "publication effect receipt is malformed"
      end

      def build_effect_gateway(token, kind, phase, payload, capture, attempt_id:,
                               persist_publication: true)
        options = {
          project_root: @project_root,
          hive_state_path: @hive_state_path,
          capture: capture,
          authority: capture.owner,
          evidence_store: @effect_evidence_store,
          delivery_store: @job_store,
          claim_validator: lambda do |claim_generation:, **|
            next false unless claim_generation == token.fetch(:generation)

            @job_store.assert_action_claim!(token, now: now)
          rescue JobStore::StaleClaim
            false
          end,
          config_loader: @config_loader,
          capability_checker: lambda do |capability_context: nil,
                                                capability:, **|
            claim_effect_authorized?(
              token, kind,
              capability_context: capability_context,
              capability: capability
            )
          end,
          module_execution: @module_execution,
          clock: @clock
        }
        return @effect_gateway_factory.call(**options) if @effect_gateway_factory

        Hive::RefactorPatrol::EffectGateway.new(**options)
      end

      def effect_capture(token, _aggregate, _action)
        unless @effect_capture &&
               @effect_capture.reservation["job_id"] ==
                 token.fetch(:job_id)
          raise JobStore::InconsistentRecord,
                "architecture patrol effect occurrence is unavailable"
        end
        @effect_capture
      end

      def ensure_effect_occurrence(aggregate)
        existing = @job_store.occurrence_capture(
          aggregate.fetch("job_id")
        )
        return existing if existing

        raise JobStore::InconsistentRecord,
              "architecture patrol job occurrence is unavailable"
      end

      def effect_scope(token)
        {
          "job_id" => token.fetch(:job_id),
          "canonical_action_id" =>
            token.fetch(:canonical_action_id)
        }
      end

      def effect_descriptor(token, kind, phase, payload, aggregate, action,
                            attempt_id:)
        repository = aggregate.dig("source", "repository")
        base = [
          token.fetch(:job_id),
          action.fetch("canonical_action_id"),
          phase,
          attempt_id
        ].compact.join(":")
        case phase
        when PrOpener::PUSH_INTENT
          {
            sink: "branch",
            target: "#{repository}:#{payload.fetch('branch')}",
            idempotency_key: base,
            capability: "repository_write"
          }
        when PrOpener::PR_CREATE_INTENT
          {
            sink: "pull_request",
            target: "#{repository}:#{payload.fetch('branch')}",
            idempotency_key: base,
            capability: "github_pull_requests"
          }
        when "issue_create_intent"
          {
            sink: "issue",
            target: "#{repository}:#{action.fetch('family_id')}",
            idempotency_key: base,
            capability: "github_issues"
          }
        else
          raise JobStore::InconsistentRecord,
                "architecture patrol effect phase is unsupported"
        end
      end

      def external_effect_fence(token, kind)
        lambda do
          next false if token.fetch(:continuation_only) == true
          next false unless effect_authorized?(kind)
          next false if terminal_proof_available?(token)

          @job_store.assert_action_claim!(token, now: now)
          true
        end
      end

      def continuation_fence(token, aggregate)
        lambda do
          ownership = current_repository_ownership_decision(
            aggregate,
            continuation: true
          )
          next false if ownership.blocked?

          @job_store.assert_action_claim!(token, now: now)
          true
        end
      end

      def persist_publication_phase(token, kind, phase, payload, attempt_id: nil)
        if kind == "fix"
          action_transitions.record_publication_phase(
            token,
            attempt_id: attempt_id,
            phase: phase,
            payload: payload,
            now: now
          )
          return
        end

        case phase
        when PrOpener::PUSH_INTENT, "issue_create_intent"
          record_creation_intent_transition!(token, phase, payload)
        when PrOpener::PUSH_COMPLETE
          record_action_receipt_transition!(token, phase, payload)
        when PrOpener::PR_CREATE_INTENT
          current = current_action(token)
          if current.dig("receipts", "creation_intent")
            record_action_receipt_transition!(token, phase, payload)
          else
            record_creation_intent_transition!(token, phase, payload)
          end
        else
          raise JobStore::InconsistentRecord, "publication intent phase is invalid"
        end
      end

      def expected_publication_payload(kind, phase, aggregate, action, patch, expected_remote_oid:)
        if kind == "issue"
          return IssueFiler.create_intent_payload(
            canonical_action_id: action.fetch("canonical_action_id"),
            repository: aggregate.dig("source", "repository"),
            family_id: action.fetch("family_id"),
            thesis_fingerprint: action.fetch("thesis_fingerprint")
          ) if phase == "issue_create_intent"

          return nil
        end

        arguments = {
          canonical_action_id: action.fetch("canonical_action_id"),
          repository: aggregate.dig("source", "repository"),
          branch: patch.branch, commit_sha: patch.commit_sha
        }
        case phase
        when PrOpener::PUSH_INTENT
          PrOpener.push_intent_payload(**arguments, expected_remote_oid: expected_remote_oid)
        when PrOpener::PUSH_COMPLETE
          PrOpener.push_complete_payload(**arguments)
        when PrOpener::PR_CREATE_INTENT
          PrOpener.pr_create_intent_payload(**arguments)
        end
      end

      def patch_from_receipts(action, aggregate, thesis)
        receipts = action.fetch("receipts")
        key = PublicationAttempt.active_patch_key(receipts)
        return nil unless key

        patch_from_receipt(receipts.fetch(key), aggregate, action, thesis)
      rescue PublicationAttempt::Error, KeyError
        :invalid
      end

      def patch_from_receipt(receipt, aggregate, action, thesis)
        return :invalid unless receipt.is_a?(Hash)

        expected_keys = Fixer::Result.members.map(&:to_s).sort
        return :invalid unless receipt.keys.sort == expected_keys

        values = Fixer::Result.members.to_h { |member| [ member, receipt[member.to_s] ] }
        patch = Fixer::Result.new(**values)
        valid_patch?(patch, aggregate, action, thesis) ? patch : :invalid
      end

      def valid_patch?(patch, aggregate, action, thesis)
        return false unless valid_fixer_result?(patch) && patch.publishable?
        return false unless patch.branch == expected_fix_branch(action.fetch("canonical_action_id"))
        return false unless Pathname.new(patch.worktree_path.to_s).absolute?
        return false unless patch.analysis_sha == aggregate.fetch("analysis_sha")
        return false unless valid_oid?(patch.publication_base_sha) && valid_oid?(patch.commit_sha)
        return false unless patch.validation.is_a?(Hash) && patch.validation["passed"] == true
        return false unless patch.changed_paths.is_a?(Array) && patch.changed_paths.any? &&
                            patch.changed_paths == patch.changed_paths.uniq &&
                            patch.changed_paths.all? { |path| valid_patch_path?(path) }
        return false unless patch.diff_lines.is_a?(Integer) && patch.diff_lines.positive?
        return false unless patch.details.is_a?(Hash)
        # A persisted patch receipt may outlive the configuration that allowed
        # it to cross the mapped feature boundary. Revalidate publication
        # against the captured/current intersection prepared for this run so a
        # live revocation still fences an already-generated patch.
        caps = @policy_result&.config&.dig("refactor_patrol", "caps")
        if caps.is_a?(Hash) && caps["allow_cross_feature"] == true
          return true
        end

        boundary = Array(thesis.feature_boundary && thesis.feature_boundary["owned_files"]) +
                   Array(thesis.feature_boundary && thesis.feature_boundary["entrypoints"])
        (patch.changed_paths - boundary).empty?
      end

      def valid_patch_path?(value)
        return false unless nonempty?(value) && !value.include?("\\")

        path = Pathname.new(value)
        path.relative? && path.cleanpath.to_s == value &&
          path.each_filename.none? { |part| part == ".." }
      end

      def expected_fix_branch(canonical_action_id)
        "hive-refactor/#{canonical_action_id}"
      end

      def valid_oid?(value)
        value.to_s.match?(/\A[0-9a-f]{40,64}\z/)
      end

      def publication_state(current, aggregate, action, patch: nil)
        if action.fetch("kind") == "fix"
          return publication_attempt_state(current, aggregate, action, patch)
        end

        receipts = current.fetch("receipts")
        state = {}
        base = receipts["creation_intent"]
        if base
          return :invalid unless base.is_a?(Hash) && base.keys.sort == %w[payload recorded_at]

          Time.iso8601(base.fetch("recorded_at").to_s)
          payload = base.fetch("payload")
          return :invalid unless payload.is_a?(Hash)
          phase = case payload["operation"]
          when "push_branch" then PrOpener::PUSH_INTENT
          when "create_pr" then PrOpener::PR_CREATE_INTENT
          when "create_issue" then "issue_create_intent"
          end
          return :invalid unless phase

          expected_oid = payload["expected_remote_oid"]
          expected = expected_publication_payload(
            action.fetch("kind"), phase, aggregate, action, patch,
            expected_remote_oid: expected_oid
          )
          return :invalid unless payload == expected

          state[phase] = payload
        end
        [ PrOpener::PUSH_COMPLETE, PrOpener::PR_CREATE_INTENT ].each do |phase|
          next unless receipts.key?(phase)

          payload = receipts.fetch(phase)
          expected = expected_publication_payload(
            action.fetch("kind"), phase, aggregate, action, patch,
            expected_remote_oid: nil
          )
          return :invalid unless payload == expected

          state[phase] = payload
        end
        state
      rescue ArgumentError, KeyError, TypeError
        :invalid
      end

      def publication_attempt_state(current, aggregate, action, patch)
        return :invalid unless patch

        attempt_id = publication_attempt_id(patch)
        attempt = current.dig("receipts", PublicationAttempt::ATTEMPTS_KEY, attempt_id)
        return :invalid unless attempt.is_a?(Hash) && PublicationAttempt.active?(attempt)

        descriptor = attempt["descriptor"]
        return :invalid unless descriptor.is_a?(Hash) &&
                               descriptor["attempt_id"] == attempt_id &&
                               descriptor["publication_base_sha"] == patch.publication_base_sha &&
                               descriptor["commit_sha"] == patch.commit_sha

        PublicationAttempt::PHASES.each_with_object({}) do |phase, state|
          next unless attempt.key?(phase)

          payload = attempt.fetch(phase)
          expected_oid = payload.is_a?(Hash) ? payload["expected_remote_oid"] : nil
          expected = expected_publication_payload(
            action.fetch("kind"), phase, aggregate, action, patch,
            expected_remote_oid: expected_oid
          )
          return :invalid unless payload == expected

          state[phase] = payload
        end
      rescue KeyError, TypeError
        :invalid
      end

      def publication_attempt_id(patch)
        PublicationAttempt.id_for(
          publication_base_sha: patch.publication_base_sha,
          commit_sha: patch.commit_sha
        )
      end

      def superseded_patch_commits(action)
        PublicationAttempt.superseded_remote_commits(action.fetch("receipts"))
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
        receipts = action&.fetch("receipts", nil)
        receipts.is_a?(Hash) && (
          receipts["creation_intent"].is_a?(Hash) || publication_phase_evidence?(receipts)
        )
      end

      def disposition_index(aggregate)
        aggregate.fetch("dispositions").each_with_object({}) do |(name, items), index|
          items.each do |item|
            snapshot = item["thesis"]
            next unless snapshot.is_a?(Hash)

            index[item.fetch("id")] = reconstructed_entry(name, item, snapshot)
          end
        end
      end

      def effect_authorized?(kind)
        current = current_policy_result
        return false unless current.authorized?(kind)
        return false unless action_policy_signature(current.config, kind) == @policy_signatures.fetch(kind.to_s)

        gates = current_gates(current.config)
        gates.fetch("discovery") && gates.fetch(kind == "fix" ? "auto_fix" : "issue_filing") &&
          repository_effect_authorized?(current.config)
      end

      def claim_effect_authorized?(token, kind, capability_context: nil,
                                   capability: nil)
        return false if token.fetch(:continuation_only) == true
        return false unless effect_authorized?(kind)
        return true unless capability_context
        return false if capability.to_s.empty?

        case capability.to_s
        when "repository_write"
          capability_context.require_repository_write!
        when "github_pull_requests"
          capability_context.require_github_mutation!("pull_requests")
          capability_context.require_external_command!("gh")
          capability_context.require_network_host!("api.github.com")
        when "github_issues"
          capability_context.require_github_mutation!("issues")
          capability_context.require_external_command!("gh")
          capability_context.require_network_host!("api.github.com")
        when "review_handoff"
          capability_context.require_filesystem_write!(
            ".hive-state/stages/**"
          )
        else
          return false
        end
        true
      rescue Hive::Modules::CapabilityDenied
        false
      end

      def enforce_repository_authority(aggregate)
        decision = current_repository_ownership_decision(
          aggregate,
          continuation: continuation_evidence?(aggregate)
        )
        @repository_identity_reason = decision.reason
        @repository_identity_drift = decision.continuation_only? &&
                                     decision.reason == "repository_identity_drift"
        @current_repository = decision.evidence["current_repository"]
        return nil unless decision.blocked?
        return nil if decision.reason == "architecture_patrol_disabled"

        block_action_phase(aggregate, decision.reason, decision.evidence)
      rescue StandardError => e
        @repository_identity_reason = "repository_identity_unresolved"
        block_action_phase(
          aggregate,
          @repository_identity_reason,
          "error" => "#{e.class}: #{e.message}"
        )
      end

      def repository_effect_authorized?(cfg)
        repository_ownership_decision(aggregate_for_source, cfg: cfg, continuation: false).full?
      end

      def transition_denial_reason(token, kind, aggregate)
        continuation = token.fetch(:continuation_only) == true
        ownership = current_repository_ownership_decision(
          aggregate,
          continuation: continuation
        )
        if ownership.blocked?
          return "authority_revoked" if ownership.reason == "architecture_patrol_disabled"

          return ownership.reason
        end
        return nil if continuation

        effect_authorized?(kind) ? nil : "authority_revoked"
      end

      def current_repository_ownership_decision(aggregate, continuation:)
        repository_ownership_decision(
          aggregate,
          cfg: load_current_config,
          continuation: continuation
        )
      rescue StandardError => e
        RepositoryOwnership::Decision.new(
          authority: :blocked,
          reason: "repository_identity_unresolved",
          evidence: { "error" => "#{e.class}: #{e.message}" }
        )
      end

      def repository_ownership_decision(aggregate, cfg:, continuation:)
        @repository_ownership.call(
          entry: {
            "name" => @registration.empty? ? aggregate.dig("source", "registration") : @registration,
            "path" => @project_root
          },
          cfg: cfg,
          expected_identity: source_identity(aggregate.fetch("source")),
          continuation: continuation,
          continuation_owner: RepositoryOwnership.remote_continuation_evidence?(aggregate)
        )
      rescue StandardError => e
        RepositoryOwnership::Decision.new(
          authority: :blocked,
          reason: "repository_identity_unresolved",
          evidence: { "error" => "#{e.class}: #{e.message}" }
        )
      end

      def aggregate_for_source
        { "source" => @source, "actions" => [] }
      end

      def source_identity(source)
        RepositoryOwnership.identity_from_source(source)
      end

      def terminal_proofs_for(aggregate, action_ids, dry_run:)
        return {} unless @canonical_action_catalog

        @canonical_action_catalog.resolve(
          action_ids: action_ids,
          expected_identity: source_identity(aggregate.fetch("source")),
          dry_run: dry_run
        )
      end

      def materialize_terminal_action(aggregate, action)
        action_id = action.fetch("canonical_action_id")
        proof = terminal_proofs_for(
          aggregate, [ action_id ], dry_run: false
        )[action_id]
        return false unless proof

        action_transitions.materialize_terminal_proof(
          aggregate, action_id, proof: proof, now: now
        )
        @events << event(
          "canonical_action_linked",
          canonical_action_id: action_id,
          owner: proof.fetch("owner"),
          linked_outcome: proof.fetch("outcome")
        )
        true
      rescue JobStore::Error => e
        raise CanonicalActionCatalog::ProofConflict,
              "cannot materialize canonical action #{action_id.inspect}: #{e.message}"
      end

      def terminal_proof_available?(token)
        aggregate = @job_store.read_job(token.fetch(:job_id))
        terminal_proofs_for(
          aggregate, [ token.fetch(:canonical_action_id) ], dry_run: false
        ).key?(token.fetch(:canonical_action_id))
      rescue CanonicalActionCatalog::Error => e
        @events << event("canonical_action_proof_unresolved", error: e.message)
        true
      end

      def refresh_terminal_catalog
        @canonical_action_catalog&.rebuild!
      rescue CanonicalActionCatalog::Error => e
        @events << event("canonical_action_catalog_refresh_failed", error: e.message)
      end

      def continuation_evidence?(aggregate)
        RepositoryOwnership.continuation_evidence?(aggregate)
      end

      def remote_continuation_evidence?(action)
        receipts = action.fetch("receipts")
        receipts["creation_intent"].is_a?(Hash) || nonempty?(receipts["pr_url"]) ||
          nonempty?(receipts["issue_url"]) || nonempty?(receipts["review_task_path"]) ||
          publication_phase_evidence?(receipts) ||
          action["outcome"].to_s.match?(/remote_outcome_unknown|pr_opened|handoff|merged/)
      end

      def publication_phase_evidence?(receipts)
        PublicationAttempt.phase_evidence?(receipts)
      end

      def prepare_policy(aggregate)
        @policy_snapshot = aggregate.fetch("policy")
        @policy_result = current_policy_result
        effective_cfg = @policy_result.config
        @policy_signatures = %w[fix issue].to_h do |kind|
          [ kind, action_policy_signature(effective_cfg, kind) ]
        end
        @fixer = @fixer_override || Fixer.new(
          @project_root, cfg: effective_cfg, clock: @clock, token_budget: @token_budget
        )
        @pr_opener = @pr_opener_override || PrOpener.new(@project_root, cfg: effective_cfg)
        @issue_filer = @issue_filer_override || IssueFiler.new(@project_root, cfg: effective_cfg)
      end

      def current_gate(name)
        current_gates.fetch(name)
      end

      def current_gates(config = nil)
        value = if @gate_reader
          @gate_reader.call
        else
          configured_gates(config || load_current_config)
        end
        {
          "discovery" => value["discovery"] == true || value[:discovery] == true,
          "auto_fix" => value["auto_fix"] == true || value[:auto_fix] == true,
          "issue_filing" => value["issue_filing"] == true || value[:issue_filing] == true
        }
      end

      def configured_gates(config)
        {
          "discovery" => config.dig("refactor_patrol", "enabled") == true,
          "auto_fix" => config.dig("refactor_patrol", "auto_fix", "enabled") == true,
          "issue_filing" => config.dig("refactor_patrol", "issue_filing", "enabled") == true
        }
      end

      def current_policy_result
        Policy.intersect(@policy_snapshot, load_current_config)
      rescue StandardError
        Policy::Result.new(
          config: @cfg,
          authority: { "fix" => false, "issue" => false },
          reasons: { "fix" => [ "current_policy_unavailable" ],
                     "issue" => [ "current_policy_unavailable" ] },
          error: "current_policy_unavailable"
        )
      end

      def load_current_config
        @config_loader.call(@project_root)
      end

      def action_policy_signature(config, kind)
        refactor = config.fetch("refactor_patrol")
        payload = if kind.to_s == "fix"
          {
            "default_branch" => config.fetch("default_branch"),
            "enabled" => refactor.fetch("enabled"),
            "auto_fix" => refactor.fetch("auto_fix"),
            "min_confidence" => refactor.fetch("min_confidence"),
            "commands" => refactor.fetch("commands"),
            "caps" => refactor.fetch("caps")
          }
        else
          {
            "enabled" => refactor.fetch("enabled"),
            "min_confidence" => refactor.fetch("min_confidence"),
            "issue_filing" => refactor.fetch("issue_filing")
          }
        end
        ::Digest::SHA256.hexdigest(JSON.generate(payload))
      rescue KeyError, TypeError, JSON::GeneratorError
        "invalid-policy"
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

      def block_action_phase(aggregate, reason, evidence = {})
        action_transitions.block(
          aggregate,
          reason: reason,
          evidence: evidence,
          backoff_sec: backoff_sec_for(reason),
          now: now
        )
      end

      def backoff_sec_for(reason)
        return @authority_backoff_sec if AUTHORITY_RECHECK_REASONS.include?(reason.to_s)

        @backoff_sec
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
