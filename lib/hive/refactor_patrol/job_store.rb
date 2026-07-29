require "json"
require "digest"
require "time"
require "uri"
require "forwardable"
require "hive/config"
require "hive/refactor_patrol/architecture_occurrence_store"
require "hive/refactor_patrol/job_occurrence_lifecycle"
require "hive/refactor_patrol/claim_transitions"
require "hive/refactor_patrol/caps"
require "hive/refactor_patrol/job_indexes"
require "hive/refactor_patrol/job_query_index"
require "hive/refactor_patrol/job_record_validator"
require "hive/refactor_patrol/job_schema_restore"
require "hive/refactor_patrol/job_store_generation_cutover"
require "hive/refactor_patrol/job_store_files"
require "hive/refactor_patrol/state_paths"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/publication_attempt"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    # Authoritative v3 lifecycle storage. A job aggregate owns discovery and
    # action receipts; the indexes below are disposable projections rebuilt by
    # scanning terminal aggregates.
    class JobStore
      SCHEMA = "hive-refactor-patrol-job".freeze
      SCHEMA_VERSION = 3
      SUPPORTED_DISCOVERY_PAYLOAD_SCHEMA_VERSIONS = [ 3 ].freeze
      ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/
      STATES = %w[queued analyzing classified acting blocked complete].freeze
      DISPOSITIONS = %w[accepted flagged suppressed].freeze
      ZERO_REASONS = %w[no_mapped_slice no_theses all_suppressed].freeze
      TOP_LEVEL_KEYS = %w[
        schema schema_version job_id occurrence_id intake_transition_id source
        analysis_sha policy state complete dispositions feature_results
        review_errors zero_reason attempts actions created_at updated_at
      ].freeze
      SOURCE_KEYS = %w[
        url number repository registration base_branch base_sha merge_sha
        merged_at changed_paths manifest_checksum
      ].freeze
      POLICY_KEYS = %w[discovery auto_fix issue_filing action epoch captured_at].freeze
      POLICY_ACTION_KEYS = %w[
        default_branch auto_fix_agent min_confidence commands caps
        issue_min_leverage_score
      ].freeze
      POLICY_ACTION_OPTIONAL_KEYS = %w[
        auto_fix_model auto_fix_effort auto_fix_launcher_identity
      ].freeze
      POLICY_COMMAND_KEYS = %w[docs format lint typecheck test].freeze
      POLICY_OPTIONAL_COMMAND_KEYS = %w[public_contract].freeze
      POLICY_CAP_KEYS = %w[
        single_feature_only allow_dependency_bumps allow_public_api_changes
        allow_cross_feature
      ].freeze
      LEGACY_POLICY_CAP_KEYS = %w[max_files max_diff_lines].freeze
      DISPOSITION_KEYS = %w[id feature_id fingerprint score admissible reasons reference thesis family_id].freeze
      FEATURE_RESULT_KEYS = %w[feature_id complete thesis_ids errors].freeze
      ACTION_REQUIRED_KEYS = %w[
        canonical_action_id thesis_id thesis_fingerprint kind owner_job_id
        outcome terminal receipts transitions
      ].freeze
      ACTION_KEYS = (ACTION_REQUIRED_KEYS + %w[
        family_id claims created_at updated_at
      ]).freeze
      ACTION_KINDS = %w[fix issue].freeze
      TERMINAL_PROOF_KEYS = %w[
        canonical_action_id outcome owner proof proof_digest
      ].freeze
      TERMINAL_PROOF_OWNER_KEYS = %w[
        registration project_root job_id pr_number merge_sha
      ].freeze
      TERMINAL_PROOF_RECEIPT_KEYS = %w[
        pr_url review_task_path issue_url issue_number duplicate_issue_urls
      ].freeze
      ACTION_CLAIM_KEYS = %w[
        owner owner_pid owner_process_start_time occurrence_id generation state
        authority claimed_at heartbeat_at expires_at pid process_start_time
        pgid finished_at outcome next_eligible_at
      ].freeze
      DISCOVERY_ATTEMPT_KEYS = %w[
        kind owner owner_pid owner_process_start_time occurrence_id generation
        state transitions claimed_at heartbeat_at expires_at pid
        process_start_time pgid finished_at outcome next_eligible_at
      ].freeze
      DIAGNOSTIC_ATTEMPT_KEYS = %w[
        kind occurrence_id generation state reason evidence transitions
        finished_at next_eligible_at
      ].freeze
      DIAGNOSTIC_ATTEMPT_OPTIONAL_KEYS =
        %w[action_claim_generations].freeze
      JOB_TRANSITION_ATTEMPT_KEYS = %w[
        kind operation occurrence_id generation transitions recorded_at
      ].freeze
      DIAGNOSTIC_ATTEMPT_KINDS =
        %w[discovery_block action_block].freeze
      JOB_TRANSITION_ATTEMPT_KIND = "job_transition".freeze
      TRANSITION_KEYS = %w[
        intent_id operation generation semantic_digest outcome error_code
        recorded_at
      ].freeze
      TRANSITION_OUTCOMES = %w[applied rejected].freeze
      MAX_TRANSITIONS_PER_GENERATION = 256
      ACTIVE_ACTION_CLAIM_STATES = %w[claimed running].freeze

      class Error < StandardError
        attr_reader :path

        def initialize(message, path: nil)
          @path = path
          super(path ? "#{message}: #{path}" : message)
        end
      end

      class CorruptRecord < Error; end
      class UnsupportedVersion < Error; end
      class InconsistentRecord < Error; end
      class RecordNotFound < Error; end
      class StaleClaim < Error; end

      DISCOVERY_ATTEMPT_KIND = "discovery_claim".freeze
      ACTIVE_CLAIM_STATES = %w[claimed running].freeze

      attr_reader :project_root, :root

      class << self
        def root_for(project_root, hive_state_path: nil)
          StatePaths.current_root(
            state_path_for(project_root, hive_state_path)
          )
        end

        def legacy_root_for(project_root, hive_state_path: nil)
          StatePaths.legacy_root(
            state_path_for(project_root, hive_state_path)
          )
        end

        def schema_state_present?(project_root, hive_state_path: nil)
          [
            root_for(project_root, hive_state_path: hive_state_path),
            legacy_root_for(project_root, hive_state_path: hive_state_path)
          ].any? do |root|
            File.lstat(root)
            true
          rescue Errno::ENOENT
            false
          end
        end

        def migrate_schema!(
          project_root,
          hive_state_path: nil,
          project: nil,
          ownership: nil,
          writer_fence:
            Hive::RefactorPatrol::MigrationWriterFence.new,
          validator: JobRecordValidator.new(contract: self)
        )
          generation_cutover(
            project_root,
            hive_state_path: hive_state_path,
            project: project,
            ownership: ownership,
            writer_fence: writer_fence,
            validator: validator
          ).run!
        end

        def ensure_schema_namespace!(
          project_root,
          hive_state_path: nil,
          project: nil,
          ownership: nil,
          writer_fence:
            Hive::RefactorPatrol::MigrationWriterFence.new,
          validator: JobRecordValidator.new(contract: self)
        )
          generation_cutover(
            project_root,
            hive_state_path: hive_state_path,
            project: project,
            ownership: ownership,
            writer_fence: writer_fence,
            validator: validator
          ).ensure_native_namespace!
        end

        def schema_status(project_root, hive_state_path: nil, project: nil)
          generation_cutover(
            project_root,
            hive_state_path: hive_state_path,
            project: project
          ).status
        end

        def schema_admission_status(project_root, hive_state_path: nil,
                                    project: nil)
          generation_cutover(
            project_root,
            hive_state_path: hive_state_path,
            project: project
          ).admission_status
        end

        def schema_snapshot_id(project_root, hive_state_path: nil,
                               project: nil)
          generation_cutover(
            project_root,
            hive_state_path: hive_state_path,
            project: project
          ).snapshot_identity
        end

        def canonical_action_id(repository:, kind:, identity:,
                                host: "github.com")
          normalized_host = host.to_s.strip.downcase
          uri = URI.parse("https://#{normalized_host}")
          unless !normalized_host.empty? &&
                 uri.host == normalized_host &&
                 uri.path.empty? &&
                 uri.userinfo.nil? &&
                 uri.query.nil? &&
                 uri.fragment.nil?
            raise InconsistentRecord,
                  "canonical action host must be an exact hostname"
          end
          normalized_repository = repository.to_s.strip.downcase
          unless normalized_repository.match?(
            %r{\A[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*\z}
          )
            raise InconsistentRecord,
                  "canonical action repository must be an owner/name identity"
          end
          action_kind = kind.to_s
          unless ACTION_KINDS.include?(action_kind)
            raise InconsistentRecord,
                  "canonical action kind must be one of #{ACTION_KINDS.inspect}"
          end
          action_identity = identity.to_s.strip
          if action_identity.empty?
            raise InconsistentRecord,
                  "canonical action identity must be non-empty"
          end

          payload = [
            normalized_host,
            normalized_repository,
            action_kind,
            action_identity
          ]
          "#{action_kind}-#{::Digest::SHA256.hexdigest(JSON.generate(payload))}"
        rescue URI::InvalidURIError
          raise InconsistentRecord,
                "canonical action host must be an exact hostname"
        end

        def restore_schema_v2_snapshot!(
          project_root,
          snapshot_id:,
          hive_state_path: nil,
          project: nil,
          writer_fence:
            Hive::RefactorPatrol::MigrationWriterFence.new(
              allow_current_process: false,
              operation: "JobStore schema restore"
            )
        )
          state = File.expand_path(
            hive_state_path || ".hive-state",
            File.expand_path(project_root)
          )
          identity = project_identity(project_root, project)
          Hive::Modules::Migration::Patrols.with_migration_lock(
            project_root,
            hive_state_path: state,
            shared: false
          ) do
            JobSchemaRestore.new(
              target_root: root_for(
                project_root, hive_state_path: state
              ),
              legacy_root: legacy_root_for(
                project_root, hive_state_path: state
              ),
              target_version: SCHEMA_VERSION,
              validator: JobRecordValidator.new(contract: self),
              corrupt_record: CorruptRecord,
              inconsistent_record: InconsistentRecord,
              project_id: identity.fetch("project_id"),
              anchor: state,
              writer_fence: writer_fence
            ).restore!(snapshot_id: snapshot_id)
          end
        end

        private

        def generation_cutover(
          project_root,
          hive_state_path: nil,
          project: nil,
          ownership: nil,
          writer_fence:
            Hive::RefactorPatrol::MigrationWriterFence.new,
          validator: JobRecordValidator.new(contract: self)
        )
          state = state_path_for(project_root, hive_state_path)
          JobStoreGenerationCutover.new(
            legacy_root: StatePaths.legacy_root(state),
            target_root: StatePaths.current_root(state),
            target_version: SCHEMA_VERSION,
            validator: validator,
            corrupt_record: CorruptRecord,
            inconsistent_record: InconsistentRecord,
            project: project_identity(project_root, project),
            ownership: ownership,
            anchor: state,
            writer_fence: writer_fence
          )
        end

        def state_path_for(project_root, hive_state_path)
          File.expand_path(
            hive_state_path || ".hive-state",
            File.expand_path(project_root)
          )
        end

        def project_identity(project_root, project)
          return project if project

          expanded_root = File.expand_path(project_root)
          registered = Hive::Config.registered_projects.select do |entry|
            File.expand_path(entry.fetch("path")) == expanded_root
          end
          if registered.size > 1
            raise ArgumentError,
                  "JobStore project identity is ambiguous for #{expanded_root}"
          end
          registered.first || {
            "name" => File.basename(File.expand_path(project_root)),
            "project_id" =>
              "local-#{Digest::SHA256.hexdigest(File.expand_path(project_root))}"
          }
        end
      end

      def initialize(project_root, hive_state_path: nil, migrate: true,
                     project: nil, ownership: nil, writer_fence: nil)
        @project_root = File.expand_path(project_root)
        @hive_state_path = File.expand_path(hive_state_path || ".hive-state", @project_root)
        @root = self.class.root_for(@project_root, hive_state_path: @hive_state_path)
        @record_validator = JobRecordValidator.new(contract: self.class)
        @job_files = JobStoreFiles.new(
          root: @root,
          anchor: @hive_state_path,
          corrupt_record: CorruptRecord,
          inconsistent_record: InconsistentRecord
        )
        @schema_options = {
          hive_state_path: @hive_state_path,
          project: project,
          ownership: ownership,
          validator: @record_validator
        }
        @schema_options[:writer_fence] = writer_fence if writer_fence
        @schema_namespace_ready = false
        self.class.migrate_schema!(
          @project_root, **@schema_options
        ) if migrate
        @claim_transitions = ClaimTransitions.new(inconsistent_record: InconsistentRecord)
        @job_indexes = JobIndexes.new(
          schema_version: SCHEMA_VERSION,
          dispositions: DISPOSITIONS,
          inconsistent_record: InconsistentRecord
        )
        @job_query_index = JobQueryIndex.new(
          files: @job_files,
          id_pattern: ID_PATTERN,
          corrupt_record: CorruptRecord,
          inconsistent_record: InconsistentRecord,
          max_entries: JobStoreFiles::MAX_JOB_ENTRIES
        )
        @architecture_occurrences = ArchitectureOccurrenceStore.new(
          root: @root,
          job_reader: method(:read_job),
          id_validator: method(:validate_id!),
          corrupt_record: CorruptRecord,
          inconsistent_record: InconsistentRecord
        )
        @occurrence_lifecycle = JobOccurrenceLifecycle.new(
          inconsistent_record: InconsistentRecord,
          record_validator: @record_validator,
          aggregate_reader: lambda do |job|
            job.is_a?(Hash) ? json_copy(job) : read_job(job)
          end,
          job_path: method(:job_path),
          before_mutation: method(:prepare_schema_namespace!),
          architecture_occurrences: -> { @architecture_occurrences }
        )
      end

      # Architecture Patrol owns one durable occurrence per immutable job.
      # Discovery claims and every later action generation reuse this identity;
      # action claim generations remain authorization fences, not effect IDs.
      extend Forwardable
      def_delegators :@occurrence_lifecycle,
                    :reserve_manifest_occurrence!, :reserve_occurrence!,
                    :occurrence_for_job, :occurrence_capture,
                    :each_recovery_active_occurrence, :recovery_active?,
                    :rebuild_recovery_index!, :recovery_backoff,
                    :record_recovery_failure!,
                    :clear_recovery_failure!, :prepare_effect!, :effect_state,
                    :effect_intent, :recorded_effect_transitions,
                    :unsettled_recorded_transitions,
                    :assert_recorded_transitions_terminal!,
                    :with_effect_sender_lock, :mark_dispatch_uncertain!,
                    :reset_effect_prepared!, :settle_effect!, :deny_effect!,
                    :effect_receipt, :terminal_effect_receipt_ids,
                    :finalize_occurrence!, :drain_occurrence_outbox!

      def record_job_transition_rejection!(job_id, operation:, generation:,
                                           transition:, now: Time.now)
        mutate_job(job_id) do |aggregate, _path|
          appended = append_job_transition!(
            aggregate,
            operation: operation,
            transition: transition,
            generation: generation,
            now: now,
            outcome: "rejected"
          )
          aggregate["updated_at"] = now.utc.iso8601 if appended
          aggregate
        end
      end


      # Intake is the only bridge from an immutable PR manifest to the
      # authoritative lifecycle aggregate. The per-job lock makes duplicate
      # watcher/reconciler producers preserve the first policy snapshot and
      # timestamp instead of racing two otherwise equivalent queued writes.
      def enqueue_manifest!(manifest, policy:, occurrence_id:,
                            intake_transition_id:, now: Time.now,
                            dry_run: false)
        data = json_copy(manifest)
        source = source_from_manifest(data)
        aggregate = queued_aggregate(
          job_id: data.fetch("job_id"),
          source: source,
          policy: json_copy(policy),
          occurrence_id: occurrence_id,
          intake_transition_id: intake_transition_id,
          now: now
        )
        validate_job!(aggregate)
        return aggregate if dry_run

        prepare_schema_namespace!
        job_id = aggregate.fetch("job_id")
        path = job_path(job_id)
        result = @job_files.with_job_admission(job_id) do
          existing_file = @job_files.job_exists?(job_id)
          @job_query_index.with_registration(
            job_id,
            existing: existing_file,
            migration_job_ids: method(:ordered_job_query_ids)
          ) do
            if existing_file
              existing = read_job(job_id)
              unless existing.fetch("source") == source
                quarantine_job_source!(
                  job_id,
                  authoritative: existing.fetch("source"),
                  candidate: source
                )
                raise InconsistentRecord.new("refactor patrol intake source is immutable", path: path)
              end
              unless existing.fetch("occurrence_id") ==
                     aggregate.fetch("occurrence_id") &&
                     existing.fetch("intake_transition_id") ==
                       aggregate.fetch("intake_transition_id")
                raise InconsistentRecord.new(
                  "refactor patrol intake occurrence identity is immutable",
                  path: path
                )
              end
              existing
            else
              atomic_write(path, aggregate)
              aggregate
            end
          end
        end
        result
      rescue KeyError => e
        raise CorruptRecord, "refactor patrol manifest is missing #{e.key.inspect}"
      end

      # Expose independently due intake jobs so one old backoff-bound
      # occurrence cannot hide later work.
      def eligible_jobs(now: Time.now)
        eligible_from(jobs, now: now).sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError => e
        raise InconsistentRecord, "refactor patrol job has invalid scheduling timestamp (#{e.message})"
      end

      def eligible_from(records, now:)
        records.select do |aggregate|
          next false if aggregate.fetch("complete")
          next false unless %w[queued blocked].include?(aggregate.fetch("state"))
          next false if aggregate.fetch("actions").any?

          deadline = aggregate.fetch("attempts").reverse_each.filter_map { |attempt| attempt["next_eligible_at"] }.first
          deadline.nil? || Time.iso8601(deadline) <= now
        end
      end
      private :eligible_from

      # Includes an expired analyzing claim so a restarted daemon can prove
      # the prior process group gone (or terminate it) before fencing a new
      # generation. The claim CAS remains authoritative.
      def claimable_jobs(now: Time.now)
        records = jobs
        (eligible_from(records, now: now) + records.select do |aggregate|
          next false unless aggregate.fetch("state") == "analyzing"

          attempt = active_discovery_attempt(aggregate)
          attempt && Time.iso8601(attempt.fetch("expires_at")) <= now
        end).uniq { |aggregate| aggregate.fetch("job_id") }
          .sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol claim has invalid scheduling evidence (#{e.message})"
      end

      # Action scheduling is intentionally separate from discovery scheduling:
      # an action-blocked job must never be sent back through read-only review.
      def actionable_jobs(now: Time.now)
        jobs.select do |aggregate|
          next false if aggregate.fetch("complete")
          next false unless %w[classified acting blocked].include?(aggregate.fetch("state"))
          next false if action_phase_backoff_active?(aggregate, now: now)
          next true if aggregate.fetch("actions").empty? && aggregate.fetch("state") == "classified"

          actions = aggregate.fetch("actions")
          active = actions.filter_map { |action| active_action_claim(action) }.first
          next Time.iso8601(active.fetch("expires_at")) <= now if active

          actions.any? do |action|
            next false if action.fetch("terminal")
            if action.fetch("owner_job_id") != aggregate.fetch("job_id")
              next linked_action_ready?(action)
            end

            !action_backoff_active?(action, now)
          end
        end.sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol action has invalid scheduling evidence (#{e.message})"
      end

      def linked_action_ready?(action)
        owner = read_job(action.fetch("owner_job_id"))
        owner_action = owner.fetch("actions").find do |candidate|
          candidate.fetch("canonical_action_id") ==
            action.fetch("canonical_action_id")
        end
        owner_action&.fetch("terminal") == true
      end

      def action_phase_backoff_active?(aggregate, now: Time.now)
        attempt = aggregate.fetch("attempts").reverse_each.find do |item|
          item["kind"] == "action_block"
        end
        deadline = attempt && attempt["next_eligible_at"]
        !deadline.nil? && Time.iso8601(deadline) > now
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol action backoff is invalid (#{e.message})"
      end

      def block_actions!(job_id, reason:, evidence: {}, now: Time.now,
                         backoff_sec: 60, episode: nil, transition: nil)
        mutate_job(job_id) do |aggregate, _path|
          next aggregate if aggregate.fetch("complete")

          timestamp = now.utc.iso8601
          generation = diagnostic_episode!(
            aggregate, "action_block", episode
          )
          aggregate.fetch("attempts") << {
            "kind" => "action_block",
            "occurrence_id" => aggregate.fetch("occurrence_id"),
            "generation" => generation,
            "state" => "blocked",
            "reason" => reason.to_s,
            "evidence" => json_copy(evidence),
            "transitions" => transition ? [
              transition_record(
                transition, generation: generation, now: now
              )
            ] : [],
            "action_claim_generations" => aggregate.fetch("actions").to_h do |action|
              generation = Array(action["claims"]).filter_map { |claim| claim["generation"] }.max.to_i
              [ action.fetch("canonical_action_id"), generation ]
            end,
            "finished_at" => timestamp,
            "next_eligible_at" => (now + backoff_sec.to_i).utc.iso8601
          }
          aggregate["state"] = aggregate.fetch("actions").empty? ? "classified" : "blocked"
          aggregate["complete"] = false
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      def next_diagnostic_episode(job, kind)
        aggregate = job.is_a?(Hash) ? json_copy(job) : read_job(job)
        diagnostic_generation(aggregate, kind.to_s) + 1
      end

      def claim_discovery!(job_id, owner:, analysis_sha:, now: Time.now, lease_sec: 3600,
                           claim_resolver: nil, owner_pid: nil,
                           owner_process_start_time: nil, transition: nil)
        mutate_job(job_id) do |aggregate, path|
          return nil if aggregate.fetch("complete")
          return nil unless %w[queued blocked analyzing].include?(aggregate.fetch("state"))
          return nil if aggregate.fetch("actions").any?

          active = active_discovery_attempt(aggregate)
          if active
            return nil if Time.iso8601(active.fetch("expires_at")) > now
            resolved = begin
              claim_resolver&.call(json_copy(active))
            rescue StandardError
              :unresolved
            end
            return nil unless resolved == :resolved

            @claim_transitions.finish!(
              active,
              state: "superseded",
              outcome: "expired_claim_resolved",
              now: now,
              touch_heartbeat: false
            )
          end

          pinned = aggregate["analysis_sha"]
          if pinned && pinned != analysis_sha.to_s
            raise InconsistentRecord.new("refactor patrol analysis checkout changed after pin", path: path)
          end
          timestamp = now.utc.iso8601
          attempt = @claim_transitions.build_discovery(
            attempts: aggregate.fetch("attempts"),
            kind: DISCOVERY_ATTEMPT_KIND,
            owner: owner,
            owner_pid: owner_pid,
            owner_process_start_time: owner_process_start_time,
            occurrence_id: aggregate.fetch("occurrence_id"),
            now: now,
            lease_sec: lease_sec
          )
          aggregate["analysis_sha"] ||= analysis_sha.to_s
          append_transition!(
            attempt.fetch("transitions"),
            transition_record(
              transition, generation: attempt.fetch("generation"), now: now
            )
          ) if transition
          aggregate["state"] = "analyzing"
          aggregate["complete"] = false
          aggregate.fetch("attempts") << attempt
          aggregate["updated_at"] = timestamp
          [ aggregate, claim_token(aggregate, attempt) ]
        end
      end

      def attach_discovery_process!(token, pid:, process_start_time:, pgid:, now: Time.now,
                                    lease_sec: nil)
        validate_lease_sec!(lease_sec) unless lease_sec.nil?
        mutate_claim(token, now: now) do |aggregate, attempt|
          @claim_transitions.attach_process!(
            attempt,
            pid: pid,
            process_start_time: process_start_time,
            pgid: pgid,
            now: now,
            lease_sec: lease_sec,
            invalid_message: "refactor patrol child identity is incomplete"
          )
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      # Read-fence equivalent for discovery transitions. The claim lock and
      # generation/lease checks are shared with all discovery mutations.
      def assert_discovery_claim!(token, now: Time.now)
        mutate_claim(token, now: now) do |aggregate, _attempt|
          aggregate
        end
        true
      end

      # Heartbeats are generation-fenced and refuse expired claims. The
      # liveness resolver gates renewal on proof of death, not proof of life:
      # renewal is refused only when the recorded PID/start-time tuple is
      # provably gone or replaced (:resolved) — or when no evidence could be
      # obtained at all — while examined-but-indeterminate evidence
      # (:unresolved) permits the renewal. The fail-closed side lives in the
      # takeover paths (claim_discovery!/claim_action!), which require
      # :resolved before a new generation may supersede an expired claim.
      # Leases extend from the heartbeat time rather than the original claim
      # time so a legitimate long review cannot be mistaken for abandoned work.
      def renew_discovery_claim!(token, now: Time.now, lease_sec: 3600, claim_resolver: nil)
        validate_lease_sec!(lease_sec)
        mutate_claim(token, now: now) do |aggregate, attempt|
          assert_claim_live!(attempt, claim_resolver)
          timestamp = now.utc.iso8601
          @claim_transitions.renew!(attempt, now: now, lease_sec: lease_sec)
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      def release_discovery!(token, reason:, now: Time.now, backoff_sec: 60,
                             transition: nil)
        mutate_claim(token, now: now) do |aggregate, attempt|
          timestamp = now.utc.iso8601
          append_transition!(
            attempt.fetch("transitions"),
            transition_record(
              transition, generation: attempt.fetch("generation"), now: now
            )
          ) if transition
          @claim_transitions.finish!(
            attempt,
            state: "released",
            outcome: reason.to_s,
            now: now,
            next_eligible_at: (now + backoff_sec.to_i).utc.iso8601,
            touch_heartbeat: false
          )
          aggregate["state"] = "blocked"
          aggregate["complete"] = false
          aggregate["review_errors"] = []
          aggregate["zero_reason"] = nil
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      # Checkout/identity failures before a claim still need durable evidence
      # and retry throttling; otherwise the daemon would repeat shell/network
      # probes and identical log lines on every fast tick.
      def block_discovery!(job_id, reason:, evidence: {}, now: Time.now,
                           backoff_sec: 60, episode: nil, transition: nil)
        mutate_job(job_id) do |aggregate, _path|
          next aggregate if aggregate.fetch("complete")

          timestamp = now.utc.iso8601
          generation = diagnostic_episode!(
            aggregate, "discovery_block", episode
          )
          aggregate.fetch("attempts") << {
            "kind" => "discovery_block",
            "occurrence_id" => aggregate.fetch("occurrence_id"),
            "generation" => generation,
            "state" => "blocked",
            "reason" => reason.to_s,
            "evidence" => json_copy(evidence),
            "transitions" => transition ? [
              transition_record(
                transition, generation: generation, now: now
              )
            ] : [],
            "finished_at" => timestamp,
            "next_eligible_at" => (now + backoff_sec.to_i).utc.iso8601
          }
          aggregate["state"] = "blocked"
          aggregate["complete"] = false
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      def checkpoint_discovery!(token, envelope:, now: Time.now,
                                backoff_sec: 60, transition: nil)
        payload = json_copy(envelope)
        mutate_claim(token, now: now) do |aggregate, attempt|
          assert_matching_discovery_payload!(aggregate, payload)
          merge_discovery_progress!(aggregate, payload)
          append_transition!(
            attempt.fetch("transitions"),
            transition_record(
              transition, generation: attempt.fetch("generation"), now: now
            )
          ) if transition
          timestamp = now.utc.iso8601
          if payload.fetch("complete")
            aggregate["review_errors"] = []
            aggregate["zero_reason"] = payload.fetch("zero_reason")
            terminal = !action_authorized_for?(aggregate)
            aggregate["state"] = terminal ? "complete" : "classified"
            aggregate["complete"] = terminal
            @claim_transitions.finish!(
              attempt,
              state: "complete",
              outcome: terminal ? "complete" : "classified",
              now: now,
              touch_heartbeat: false
            )
          else
            aggregate["review_errors"] = json_copy(payload.fetch("review_errors"))
            aggregate["zero_reason"] = nil
            aggregate["state"] = "blocked"
            aggregate["complete"] = false
            @claim_transitions.finish!(
              attempt,
              state: "released",
              outcome: "partial_review",
              now: now,
              next_eligible_at: (now + backoff_sec.to_i).utc.iso8601,
              touch_heartbeat: false
            )
          end
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      # A successful feature is committed while the discovery claim remains
      # active. Only complete feature slices enter the aggregate; an eventual
      # malformed/partial result is still handled by checkpoint_discovery!,
      # while a process death can resume after the last committed slice.
      def checkpoint_discovery_progress!(token, envelope:, now: Time.now,
                                         lease_sec: 3600,
                                         transition: nil)
        validate_lease_sec!(lease_sec)
        payload = json_copy(envelope)
        mutate_claim(token, now: now) do |aggregate, attempt|
          assert_matching_discovery_payload!(aggregate, payload, intermediate: true)
          merge_discovery_progress!(aggregate, payload)
          append_transition!(
            attempt.fetch("transitions"),
            transition_record(
              transition, generation: attempt.fetch("generation"), now: now
            )
          ) if transition
          timestamp = now.utc.iso8601
          @claim_transitions.renew!(attempt, now: now, lease_sec: lease_sec)
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      def record_discovery_transition_rejection!(token, transition:,
                                                 now: Time.now)
        mutate_claim(token, now: now) do |aggregate, attempt|
          append_transition!(
            attempt.fetch("transitions"),
            transition_record(
              transition,
              generation: attempt.fetch("generation"),
              now: now,
              outcome: "rejected"
            )
          )
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      # Canonical action ids are deliberately opaque: incorporating a digest
      # keeps repository names, family ids, and fingerprints out of filesystem
      # paths while still binding all three identity dimensions.
      def canonical_action_id(repository:, kind:, identity:, host: "github.com")
        self.class.canonical_action_id(
          repository: repository,
          host: host,
          kind: kind,
          identity: identity
        )
      end

      # Classification is immutable. This transition snapshots only the action
      # set derived by the caller after semantic-family resolution. Repeating
      # the exact snapshot is idempotent; attempts to add authority later fail.
      def plan_actions(job_id, specifications:)
        specs = json_copy(specifications)
        unless specs.is_a?(Array) && specs.all? { |item| item.is_a?(Hash) }
          raise CorruptRecord, "action specifications must be an array of objects"
        end

        aggregate = read_job(job_id)
        normalize_action_specifications(aggregate, specs, job_path(aggregate.fetch("job_id")))
      end

      def initialize_actions!(job_id, specifications:, terminal_proofs: {},
                              now: Time.now, transition: nil,
                              transition_generation: nil)
        specs = json_copy(specifications)
        unless specs.is_a?(Array) && specs.all? { |item| item.is_a?(Hash) }
          raise CorruptRecord, "action specifications must be an array of objects"
        end

        with_action_catalog_lock do
          mutate_job(job_id) do |aggregate, path|
            normalized = normalize_action_specifications(aggregate, specs, path)
            proofs = normalize_terminal_proofs(terminal_proofs, normalized, path)
            existing = aggregate.fetch("actions")
            if existing.any?
              unless initialized_action_identity(existing) == initialized_action_identity(normalized)
                raise InconsistentRecord.new("refactor patrol action snapshot is immutable", path: path)
              end

              append_job_transition!(
                aggregate,
                operation: "initialize-actions",
                transition: transition,
                generation: transition_generation,
                now: now
              ) if transition
              next aggregate
            end
            if aggregate.fetch("complete")
              if normalized.any?
                raise InconsistentRecord.new("complete job cannot gain actions without explicit replay", path: path)
              end

              next aggregate
            end

            timestamp = now.utc.iso8601
            aggregate["actions"] = normalized.map do |specification|
              initialized_action(
                aggregate, specification, timestamp,
                terminal_proof: proofs[specification.fetch("canonical_action_id")]
              )
            end
            append_job_transition!(
              aggregate,
              operation: "initialize-actions",
              transition: transition,
              generation: transition_generation,
              now: now
            ) if transition
            recompute_parent_state!(aggregate)
            aggregate["updated_at"] = timestamp
            aggregate
          end
        end
      end

      # Materialize proof that became terminal after the immutable action plan
      # was initialized but before this occurrence began a remote transition.
      # Finished claim history is retained; any active claim or receipt makes
      # the race ambiguous and therefore blocks instead of overwriting state.
      def materialize_terminal_proof!(job_id, canonical_action_id, proof:,
                                      now: Time.now, transition: nil,
                                      transition_generation: nil)
        normalized = validate_terminal_proof!(json_copy(proof), canonical_action_id, job_path(job_id))
        mutate_job(job_id) do |aggregate, path|
          action = find_action!(aggregate, canonical_action_id, path)
          if action.fetch("terminal")
            existing = action.dig("receipts", "canonical_action_link")
            unless existing == normalized
              raise InconsistentRecord.new("terminal canonical action proof conflicts", path: path)
            end
            next aggregate
          end
          unless action.fetch("owner_job_id") == aggregate.fetch("job_id")
            raise InconsistentRecord.new("linked action must reconcile through its local owner", path: path)
          end
          if active_action_claim(action) || !action.fetch("receipts").empty?
            raise InconsistentRecord.new(
              "canonical action already began a local or remote transition", path: path
            )
          end

          apply_terminal_proof!(action, normalized, now)
          append_transition!(
            action.fetch("transitions"),
            transition_record(
              transition,
              generation: transition_generation,
              now: now
            )
          ) if transition
          recompute_parent_state!(aggregate)
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      # One active fenced claim exists per canonical action. An expired claim
      # is not replaced until the caller supplies liveness evidence that the
      # previous worker has been resolved.
      def claim_action!(job_id, canonical_action_id, owner:, now: Time.now, lease_sec: 3600,
                        claim_resolver: nil, owner_pid: nil, owner_process_start_time: nil,
                        authority: true, transition: nil)
        raise InconsistentRecord, "action claim owner must be non-empty" if owner.to_s.empty?
        unless lease_sec.is_a?(Integer) && lease_sec.positive?
          raise InconsistentRecord, "action claim lease_sec must be a positive integer"
        end

        mutate_job(job_id) do |aggregate, path|
          return nil if aggregate.fetch("complete")

          action = find_action!(aggregate, canonical_action_id, path)
          return nil if action.fetch("terminal")
          return nil if another_action_active?(aggregate, action)
          unless action.fetch("owner_job_id") == aggregate.fetch("job_id")
            raise InconsistentRecord.new("linked canonical action must be reconciled from its owner", path: path)
          end

          claims = action["claims"] ||= []
          active = active_action_claim(action)
          if active
            return nil if Time.iso8601(active.fetch("expires_at")) > now

            resolved = begin
              claim_resolver&.call(json_copy(active))
            rescue StandardError
              :unresolved
            end
            return nil unless resolved == :resolved

            @claim_transitions.finish!(
              active, state: "superseded", outcome: "expired_claim_resolved", now: now
            )
          elsif action_backoff_active?(action, now)
            return nil
          end

          continuation_only = authority != true
          if continuation_only && !continuation_after_revocation?(action)
            action["outcome"] = "authority_revoked"
            action["updated_at"] = now.utc.iso8601 if action.key?("updated_at")
            aggregate["state"] = "blocked"
            aggregate["updated_at"] = now.utc.iso8601
            next [ aggregate, nil ]
          end

          timestamp = now.utc.iso8601
          claim = @claim_transitions.build_action(
            claims: claims,
            owner: owner,
            owner_pid: owner_pid,
            owner_process_start_time: owner_process_start_time,
            occurrence_id: aggregate.fetch("occurrence_id"),
            authority: continuation_only ? "continuation_only" : "full",
            now: now,
            lease_sec: lease_sec
          )
          claims << claim
          append_transition!(
            action.fetch("transitions"),
            transition_record(
              transition, generation: claim.fetch("generation"), now: now
            )
          ) if transition
          action["outcome"] = "claimed" unless continuation_only
          action["updated_at"] = timestamp if action.key?("updated_at")
          aggregate["state"] = "acting"
          aggregate["updated_at"] = timestamp
          [ aggregate, action_claim_token(aggregate, action, claim) ]
        end
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol action claim has invalid evidence (#{e.message})"
      end

      def attach_action_process!(token, pid:, process_start_time:, pgid:, now: Time.now)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          @claim_transitions.attach_process!(
            claim,
            pid: pid,
            process_start_time: process_start_time,
            pgid: pgid,
            now: now,
            invalid_message: "refactor patrol action child identity is incomplete"
          )
          touch_action!(aggregate, action, now)
        end
      end

      # Same renewal semantics as renew_discovery_claim!: refusal requires
      # proof of death/PID reuse (or no obtainable evidence); the fail-closed
      # takeover lives in claim_action!.
      def renew_action_claim!(token, now: Time.now, lease_sec: 3600, claim_resolver: nil)
        validate_lease_sec!(lease_sec)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          assert_claim_live!(claim, claim_resolver)
          @claim_transitions.renew!(claim, now: now, lease_sec: lease_sec)
          touch_action!(aggregate, action, now)
        end
      end

      # The command child does not receive the daemon's opaque dispatch token.
      # It can discover only an active claim bound to its exact PID and process
      # start time, then every renewal still performs the normal generation
      # CAS. Matching owner identity covers manual discovery and action claims;
      # matching child identity covers daemon-owned discovery claims.
      def active_claim_tokens_for_process(job_id, pid:, process_start_time:)
        process_pid = pid.to_i
        process_start = process_start_time.to_s
        return [] if process_pid <= 1 || process_start.empty?

        aggregate = read_job(job_id)
        tokens = []
        attempt = active_discovery_attempt(aggregate)
        if attempt && claim_process_identity?(attempt, process_pid, process_start)
          tokens << claim_token(aggregate, attempt).merge(kind: :discovery)
        end
        aggregate.fetch("actions").each do |action|
          claim = active_action_claim(action)
          next unless claim && claim_process_identity?(claim, process_pid, process_start)

          tokens << action_claim_token(aggregate, action, claim).merge(kind: :action)
        end
        tokens
      end

      # Last-moment fence for an external transition. This intentionally
      # performs no state mutation; holding the aggregate lock while checking
      # the active generation proves a superseded worker cannot proceed.
      def assert_action_claim!(token, now: Time.now)
        mutate_action_claim(token, now: now) do |aggregate, _action, _claim|
          aggregate
        end
        true
      end

      # The durable creation intent is write-once and must precede the remote
      # request. Retrying the same payload returns the authoritative aggregate;
      # a different payload is a conflicting external transaction.
      def record_creation_intent!(token, intent:, now: Time.now,
                                  transition: nil)
        payload = json_copy(intent)
        unless payload.is_a?(Hash) && payload.any?
          raise CorruptRecord, "refactor patrol creation intent must be a non-empty object"
        end

        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          existing = action.fetch("receipts")["creation_intent"]
          if claim.fetch("authority") == "continuation_only"
            unless existing && existing["payload"] == payload
              raise InconsistentRecord, "revoked action claim cannot create a new remote intent"
            end
            append_action_transition!(
              action, claim, transition, now
            ) if transition
            next aggregate
          end
          if existing
            unless existing["payload"] == payload
              raise InconsistentRecord, "refactor patrol creation intent is immutable"
            end
            append_action_transition!(
              action, claim, transition, now
            ) if transition
            next aggregate
          end

          action.fetch("receipts")["creation_intent"] = {
            "payload" => payload,
            "recorded_at" => now.utc.iso8601
          }
          append_action_transition!(
            action, claim, transition, now
          ) if transition
          touch_action!(aggregate, action, now)
        end
      end
      alias record_action_intent! record_creation_intent!

      def record_action_receipt!(token, key:, value:, now: Time.now,
                                 transition: nil)
        receipt_key = key.to_s
        if receipt_key.empty? || receipt_key == "creation_intent"
          raise InconsistentRecord, "action receipt key is invalid"
        end

        record_action_receipts!(
          token,
          receipts: { receipt_key => value },
          now: now,
          transition: transition
        )
      end

      def record_action_receipts!(token, receipts:, now: Time.now,
                                  transition: nil)
        additions = json_copy(receipts)
        unless additions.is_a?(Hash) && additions.keys.all? { |key| key.is_a?(String) && !key.empty? }
          raise CorruptRecord, "action receipts must be an object with non-empty string keys"
        end
        if additions.key?("creation_intent")
          raise InconsistentRecord, "creation intent requires record_creation_intent!"
        end
        if additions.key?(PublicationAttempt::ATTEMPTS_KEY)
          raise InconsistentRecord, "publication attempts require the fenced publication API"
        end

        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          changed = merge_receipts!(action.fetch("receipts"), additions)
          prior = action.fetch("transitions").size
          append_action_transition!(
            action, claim, transition, now
          ) if transition
          if changed || action.fetch("transitions").size != prior
            touch_action!(aggregate, action, now)
          else
            aggregate
          end
        end
      end

      def record_patch_receipt!(token, receipt:, now: Time.now,
                                transition: nil)
        payload = json_copy(receipt)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          receipts = action.fetch("receipts")
          patch_keys = receipts.keys.grep(/\Apatch(?:_\d+)?\z/).sort_by do |key|
            key == "patch" ? 1 : key.delete_prefix("patch_").to_i
          end
          if patch_keys.any? { |key| receipts.fetch(key) == payload }
            append_action_transition!(
              action, claim, transition, now
            ) if transition
            next transition ? touch_action!(aggregate, action, now) : aggregate
          end

          sequence = patch_keys.empty? ? 1 : patch_keys.map do |key|
            key == "patch" ? 1 : key.delete_prefix("patch_").to_i
          end.max + 1
          key = sequence == 1 ? "patch" : "patch_#{sequence}"
          receipts[key] = payload
          append_action_transition!(
            action, claim, transition, now
          ) if transition
          touch_action!(aggregate, action, now)
        end
      end

      # Atomically binds one validated patch receipt to its content-derived
      # publication attempt. Existing flat publication receipts are copied into
      # the matching namespace on first resume but remain readable and immutable.
      def record_patch_publication_attempt!(token, receipt:, now: Time.now,
                                            transition: nil)
        payload = json_copy(receipt)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          updated = PublicationAttempt.ensure_for_patch(
            receipts: action.fetch("receipts"),
            patch_receipt: payload,
            recorded_at: now.utc.iso8601,
            continuation_only: claim.fetch("authority") == "continuation_only"
          )
          if updated == action.fetch("receipts")
            if transition
              append_action_transition!(
                action, claim, transition, now
              )
              next touch_action!(aggregate, action, now)
            end
            next aggregate
          end

          action["receipts"] = updated
          append_action_transition!(
            action, claim, transition, now
          ) if transition
          touch_action!(aggregate, action, now)
        end
      rescue PublicationAttempt::Error => e
        raise InconsistentRecord, e.message
      end

      # Appends exactly one phase to an active publication attempt under the
      # current action-claim fence. Phase grammar and ordering are validated by
      # JobRecordValidator before the aggregate is committed.
      def record_publication_attempt_phase!(token, attempt_id:, phase:,
                                            payload:, now: Time.now,
                                            transition: nil)
        value = json_copy(payload)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          updated = PublicationAttempt.append_phase(
            receipts: action.fetch("receipts"),
            attempt_id: attempt_id,
            phase: phase,
            payload: value,
            continuation_only: claim.fetch("authority") == "continuation_only"
          )
          if updated == action.fetch("receipts")
            append_action_transition!(
              action, claim, transition, now
            ) if transition
            next transition ? touch_action!(aggregate, action, now) : aggregate
          end

          action["receipts"] = updated
          append_action_transition!(
            action, claim, transition, now
          ) if transition
          touch_action!(aggregate, action, now)
        end
      rescue PublicationAttempt::Error => e
        raise InconsistentRecord, e.message
      end

      # Trunk drift can retire only the exact active pre-create attempt. The
      # observed head is durable so a replacement cannot be authorized by an
      # uncorroborated local marker.
      def supersede_publication_attempt!(token, attempt_id:,
                                         observed_head_sha:, now: Time.now,
                                         transition: nil)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          updated = PublicationAttempt.supersede(
            receipts: action.fetch("receipts"),
            attempt_id: attempt_id,
            observed_head_sha: observed_head_sha,
            recorded_at: now.utc.iso8601
          )
          if updated == action.fetch("receipts")
            append_action_transition!(
              action, claim, transition, now
            ) if transition
            next transition ? touch_action!(aggregate, action, now) : aggregate
          end

          action["receipts"] = updated
          append_action_transition!(
            action, claim, transition, now
          ) if transition
          touch_action!(aggregate, action, now)
        end
      rescue PublicationAttempt::Error => e
        raise InconsistentRecord, e.message
      end

      def record_fix_receipt!(token, receipt:, now: Time.now,
                              transition: nil)
        record_action_receipt!(
          token,
          key: "fix",
          value: receipt,
          now: now,
          transition: transition
        )
      end

      def record_action_outcome!(token, outcome:, terminal:, receipts: {}, blocked: false, now: Time.now,
                                 backoff_sec: 0, transition: nil)
        unless [ true, false ].include?(terminal)
          raise InconsistentRecord, "action outcome terminal must be boolean"
        end
        unless [ true, false ].include?(blocked) && !(terminal && blocked)
          raise InconsistentRecord, "action outcome blocked must be boolean and nonterminal"
        end
        if blocked && (!backoff_sec.is_a?(Integer) || backoff_sec.negative?)
          raise InconsistentRecord, "action outcome backoff_sec must be a non-negative integer"
        end
        outcome_value = outcome.to_s
        raise InconsistentRecord, "action outcome must be non-empty" if outcome_value.empty?
        additions = json_copy(receipts)
        raise CorruptRecord, "action outcome receipts must be an object" unless additions.is_a?(Hash)
        if additions.key?(PublicationAttempt::ATTEMPTS_KEY)
          raise InconsistentRecord, "publication attempts require the fenced publication API"
        end

        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          normalize_creation_intent_receipt!(action.fetch("receipts"), additions)
          merge_receipts!(action.fetch("receipts"), additions)
          append_action_transition!(
            action, claim, transition, now
          ) if transition
          action["outcome"] = outcome_value
          action["terminal"] = terminal
          if terminal
            @claim_transitions.finish!(claim, state: "complete", outcome: outcome_value, now: now)
          elsif blocked
            @claim_transitions.finish!(
              claim,
              state: "released",
              outcome: outcome_value,
              now: now,
              next_eligible_at: (now + backoff_sec.to_i).utc.iso8601
            )
          end
          touch_action!(aggregate, action, now)
          recompute_parent_state!(aggregate)
          aggregate
        end
      end

      def finish_action!(token, outcome:, receipts: {}, now: Time.now,
                         transition: nil)
        record_action_outcome!(
          token,
          outcome: outcome,
          terminal: true,
          receipts: receipts,
          now: now,
          transition: transition
        )
      end

      def release_action!(token, outcome:, receipts: {}, now: Time.now,
                          backoff_sec: 60, transition: nil)
        record_action_outcome!(
          token,
          outcome: outcome,
          terminal: false,
          receipts: receipts,
          blocked: true,
          now: now,
          backoff_sec: backoff_sec,
          transition: transition
        )
      end

      def record_action_transition_rejection!(token, transition:,
                                              now: Time.now)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          append_action_transition!(
            action, claim, transition, now, outcome: "rejected"
          )
          touch_action!(aggregate, action, now)
        end
      end

      # A linked occurrence owns no receipts. It may atomically copy only the
      # owner's terminal proof so its parent can settle without duplicating an
      # external effect.
      def reconcile_linked_action!(job_id, canonical_action_id,
                                   now: Time.now, transition: nil,
                                   transition_generation: nil)
        mutate_job(job_id) do |aggregate, path|
          action = find_action!(aggregate, canonical_action_id, path)
          next aggregate if action.fetch("terminal")
          if action.fetch("owner_job_id") == aggregate.fetch("job_id")
            raise InconsistentRecord.new("owner action cannot be reconciled as a link", path: path)
          end

          owner = read_job(action.fetch("owner_job_id"))
          owner_action = find_action!(owner, canonical_action_id, job_path(owner.fetch("job_id")))
          next aggregate unless owner_action.fetch("terminal")

          action["outcome"] = owner_action.fetch("outcome")
          action["terminal"] = true
          append_transition!(
            action.fetch("transitions"),
            transition_record(
              transition,
              generation: transition_generation,
              now: now
            )
          ) if transition
          action["updated_at"] = now.utc.iso8601 if action.key?("updated_at")
          recompute_parent_state!(aggregate)
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      def write_job!(aggregate, dry_run: false)
        data = json_copy(aggregate)
        validate_job!(data)
        return data if dry_run

        prepare_schema_namespace!
        job_id = data.fetch("job_id")
        path = job_path(job_id)
        result = @job_files.with_job_admission(job_id) do
          existing_file = @job_files.job_exists?(job_id)
          @job_query_index.with_registration(
            job_id,
            existing: existing_file,
            migration_job_ids: method(:ordered_job_query_ids)
          ) do
            if existing_file
              existing = read_job(job_id)
              validate_transition!(existing, data, path)
              if existing == data
                existing
              else
                atomic_write(path, data)
                data
              end
            else
              atomic_write(path, data)
              data
            end
          end
        end
        result
      end

      def read_job(job_id)
        id = validate_id!(job_id)
        path = job_path(id)
        unless @job_files.job_exists?(id)
          raise RecordNotFound.new(
            "refactor patrol job not found",
            path: path
          )
        end

        read_job_path(path, expected_job_id: id)
      end

      def jobs
        each_job.to_a
      end

      # Bounded, snapshot-stable membership projection for the read-only jobs
      # CLI. Only selected authoritative aggregates are parsed.
      def job_query_page(limit:, cursor: nil)
        page = @job_query_index.page(limit: limit, cursor: cursor)
        page.merge("jobs" => page.fetch("job_ids").map { |job_id| read_job(job_id) })
      end

      def incomplete_jobs?
        cursor = nil
        loop do
          page = job_query_page(limit: 256, cursor: cursor)
          return true if page.fetch("jobs").any? do |aggregate|
            aggregate.fetch("complete") == false
          end
          return false unless page.fetch("has_more")

          cursor = {
            "generation" => page.fetch("generation"),
            "after_sequence" => page.fetch("next_after_sequence"),
            "through_sequence" => page.fetch("through_sequence")
          }
        end
      end

      # Explicit writer-side repair. Rebuilding changes the index generation,
      # so existing cursors fail closed instead of silently changing pages.
      def rebuild_job_query_index!
        prepare_schema_namespace!
        @job_query_index.rebuild! { ordered_job_query_ids }
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "cannot rebuild refactor patrol job query index (#{e.message})"
      end

      def each_job
        return enum_for(__method__) unless block_given?

        @job_files.each_job_id do |job_id|
          yield read_job_path(
            job_path(job_id),
            expected_job_id: job_id
          )
        end
      end

      def rebuild_indexes!
        prepare_schema_namespace!
        indexes = @job_indexes.project(each_job)
        atomic_write(fingerprint_index_path, indexes.fetch("fingerprints"))
        atomic_write(action_index_path, indexes.fetch("actions"))
        indexes
      end

      def fingerprint_index
        # Terminal aggregates are authoritative and can change after an index
        # was last read. Rebuild at the discovery boundary so recursion
        # suppression never trusts a stale projection.
        rebuild_indexes!.fetch("fingerprints")
      end

      def action_index
        read_derived_index(
          action_index_path,
          schema: JobIndexes::ACTION_SCHEMA,
          collection: "actions"
        ) { rebuild_indexes!.fetch("actions") }
      end

      def fingerprint_index_path
        File.join(root, "indexes", "fingerprints.json")
      end

      def action_index_path
        File.join(root, "indexes", "actions.json")
      end

      # Historical size caps classified otherwise admissible theses as
      # flagged. Keep that immutable classification on disk, but treat a row
      # whose complete reason/flag set consists only of those retired cap
      # codes as accepted when deciding current action authority.
      def effective_disposition(disposition, item)
        name = disposition.to_s
        return name unless name == "flagged"
        return name unless item.is_a?(Hash) && item["admissible"] == true

        thesis = item["thesis"]
        return name unless thesis.is_a?(Hash) && thesis["admissible"] == true

        findings = Array(item["reasons"]).map(&:to_s) +
                   Array(thesis.dig("risk", "flags")).map(&:to_s)
        return name if findings.empty?
        return name unless (findings - Caps::LEGACY_SIZE_FLAGS).empty?

        "accepted"
      end

      private

      def ordered_job_query_ids
        each_job.to_a.sort_by do |aggregate|
          [ Time.iso8601(aggregate.fetch("created_at")).utc, aggregate.fetch("job_id") ]
        end.map { |aggregate| aggregate.fetch("job_id") }
      end

      def with_action_catalog_lock
        prepare_schema_namespace!
        @job_files.with_action_catalog_lock { yield }
      end

      def normalize_action_specifications(aggregate, specifications, path)
        unless %w[classified acting blocked complete].include?(aggregate.fetch("state"))
          raise InconsistentRecord.new("job must be classified before actions are initialized", path: path)
        end

        dispositions = disposition_by_id(aggregate.fetch("dispositions"))
        normalized = specifications.map do |specification|
          strict_hash!(
            specification,
            required: %w[thesis_id kind],
            allowed: %w[thesis_id kind family_id],
            label: "action specification",
            path: path
          )
          thesis_id = specification.fetch("thesis_id").to_s
          kind = specification.fetch("kind").to_s
          entry = dispositions[thesis_id]
          raise InconsistentRecord.new("action thesis is not classified", path: path) unless entry

          disposition, thesis = entry
          disposition = effective_disposition(disposition, thesis)
          validate_action_authority!(aggregate, kind, disposition, thesis, path)
          family_id = specification["family_id"].to_s unless specification["family_id"].nil?
          identity = action_identity(kind, family_id, thesis, path)
          {
            "canonical_action_id" => canonical_action_id(
              repository: aggregate.dig("source", "repository"),
              host: source_host(aggregate.fetch("source")),
              kind: kind,
              identity: identity
            ),
            "thesis_id" => thesis_id,
            "thesis_fingerprint" => thesis.fetch("fingerprint"),
            "kind" => kind
          }.tap do |item|
            item["family_id"] = family_id unless family_id.to_s.empty?
          end
        end

        normalized.group_by { |item| item.fetch("canonical_action_id") }.values.map do |duplicates|
          duplicates.min_by { |item| item.fetch("thesis_id") }
        end.sort_by { |item| item.fetch("canonical_action_id") }
      end

      def validate_action_authority!(aggregate, kind, disposition, thesis, path)
        unless ACTION_KINDS.include?(kind)
          raise InconsistentRecord.new("action kind must be one of #{ACTION_KINDS.inspect}", path: path)
        end
        policy = aggregate.fetch("policy")
        case kind
        when "fix"
          unless disposition == "accepted" && policy.fetch("auto_fix")
            raise InconsistentRecord.new("fix action exceeds the immutable policy/disposition snapshot", path: path)
          end
        when "issue"
          eligible = (disposition == "flagged" && thesis.fetch("admissible")) || disposition == "accepted"
          unless eligible && policy.fetch("issue_filing")
            raise InconsistentRecord.new("issue action exceeds the immutable policy/disposition snapshot", path: path)
          end
        end
      end

      def action_identity(kind, family_id, thesis, path)
        return thesis.fetch("fingerprint") unless kind == "issue"
        if family_id.to_s.empty?
          raise InconsistentRecord.new("issue action requires a semantic family_id", path: path)
        end

        family_id
      end

      def source_host(source)
        uri = URI.parse(source.fetch("url").to_s)
        raise InconsistentRecord, "action source URL must include an exact host" unless uri.host

        uri.host
      rescue URI::InvalidURIError, KeyError
        raise InconsistentRecord, "action source URL must include an exact host"
      end

      def initialized_action_identity(actions)
        actions.map do |action|
          action.slice(
            "canonical_action_id", "thesis_id", "thesis_fingerprint", "kind", "family_id"
          ).compact
        end.sort_by { |action| action.fetch("canonical_action_id") }
      end

      def initialized_action(aggregate, specification, timestamp, terminal_proof: nil)
        owner_action = canonical_owner_action(specification.fetch("canonical_action_id"))
        owner_job_id = owner_action ? owner_action.fetch("owner_job_id") : aggregate.fetch("job_id")
        linked = owner_job_id != aggregate.fetch("job_id")
        action = {
          "canonical_action_id" => specification.fetch("canonical_action_id"),
          "thesis_id" => specification.fetch("thesis_id"),
          "thesis_fingerprint" => specification.fetch("thesis_fingerprint"),
          "kind" => specification.fetch("kind"),
          "owner_job_id" => owner_job_id,
          "outcome" => linked ? owner_action.fetch("outcome") : "queued",
          "terminal" => linked && owner_action.fetch("terminal"),
          "receipts" => {},
          "claims" => [],
          "transitions" => [],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
        action["family_id"] = specification.fetch("family_id") if specification.key?("family_id")
        apply_terminal_proof!(action, terminal_proof, Time.iso8601(timestamp)) if terminal_proof && !owner_action
        action
      end

      def normalize_terminal_proofs(proofs, specifications, path)
        value = json_copy(proofs || {})
        unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
          raise CorruptRecord.new("terminal action proofs must be an object", path: path)
        end
        ids = specifications.map { |item| item.fetch("canonical_action_id") }
        unknown = value.keys - ids
        unless unknown.empty?
          raise InconsistentRecord.new(
            "terminal action proofs contain unknown actions #{unknown.sort.inspect}", path: path
          )
        end
        value.to_h do |action_id, proof|
          [ action_id, validate_terminal_proof!(proof, action_id, path) ]
        end
      end

      def validate_terminal_proof!(proof, action_id, path)
        @record_validator.validate_terminal_proof!(proof, action_id, path)
      end

      def apply_terminal_proof!(action, proof, now)
        action["outcome"] = proof.fetch("outcome")
        action["terminal"] = true
        action["receipts"] = json_copy(proof.fetch("proof")).merge(
          "canonical_action_link" => json_copy(proof)
        )
        action["updated_at"] = now.utc.iso8601
      end

      def canonical_owner_action(action_id)
        matches = each_job.flat_map do |aggregate|
          aggregate.fetch("actions").filter_map do |action|
            next unless action.fetch("canonical_action_id") == action_id
            next unless action.fetch("owner_job_id") == aggregate.fetch("job_id")

            action
          end
        end
        if matches.size > 1
          raise InconsistentRecord, "canonical action #{action_id.inspect} has multiple owner jobs"
        end

        matches.first
      end

      def find_action!(aggregate, canonical_action_id, path)
        id = canonical_action_id.to_s
        action = aggregate.fetch("actions").find { |candidate| candidate.fetch("canonical_action_id") == id }
        raise RecordNotFound.new("refactor patrol action not found", path: path) unless action

        action
      end

      def active_action_claim(action)
        Array(action["claims"]).reverse_each.find do |claim|
          ACTIVE_ACTION_CLAIM_STATES.include?(claim["state"])
        end
      end

      def another_action_active?(aggregate, selected)
        aggregate.fetch("actions").any? do |action|
          action != selected && active_action_claim(action)
        end
      end

      def action_backoff_active?(action, now)
        deadline = Array(action["claims"]).last&.fetch("next_eligible_at", nil)
        deadline && Time.iso8601(deadline) > now
      end

      def continuation_after_revocation?(action)
        receipts = action.fetch("receipts")
        receipts.key?("creation_intent") || receipts.key?("pr") || receipts.key?("pr_url") ||
          receipts.key?("issue") || receipts.key?("issue_url") ||
          receipts.key?("review_task_path") || publication_continuation?(receipts) ||
          action.fetch("outcome").match?(/remote_outcome_unknown|pr_opened|handoff|merged/)
      end

      def action_claim_token(aggregate, action, claim)
        {
          job_id: aggregate.fetch("job_id"),
          canonical_action_id: action.fetch("canonical_action_id"),
          owner: claim.fetch("owner"),
          generation: claim.fetch("generation"),
          continuation_only: claim.fetch("authority") == "continuation_only"
        }
      end

      def claim_process_identity?(claim, pid, process_start_time)
        owner_matches = claim["owner_pid"].to_i == pid &&
                        claim["owner_process_start_time"].to_s == process_start_time
        child_matches = claim["pid"].to_i == pid &&
                        claim["process_start_time"].to_s == process_start_time
        owner_matches || child_matches
      end

      def validate_lease_sec!(lease_sec)
        unless lease_sec.is_a?(Integer) && lease_sec.positive?
          raise InconsistentRecord, "claim lease_sec must be a positive integer"
        end
      end

      def assert_claim_live!(claim, claim_resolver)
        resolution = begin
          claim_resolver&.call(json_copy(claim))
        rescue StandardError
          :unresolved_without_proof
        end
        return if resolution == :unresolved

        raise StaleClaim, "refactor patrol claim owner is provably gone, replaced, or unverifiable"
      end

      def mutate_action_claim(token, now:)
        mutate_job(token.fetch(:job_id)) do |aggregate, path|
          action = find_action!(aggregate, token.fetch(:canonical_action_id), path)
          claim = active_action_claim(action)
          unless claim && claim["owner"] == token.fetch(:owner).to_s &&
                 claim["generation"] == token.fetch(:generation).to_i
            raise StaleClaim.new("refactor patrol action claim fence is stale", path: path)
          end
          if Time.iso8601(claim.fetch("expires_at")) <= now
            raise StaleClaim.new("refactor patrol action claim lease expired", path: path)
          end

          yield aggregate, action, claim
        end
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol action claim has invalid evidence (#{e.message})"
      end

      def touch_action!(aggregate, action, now)
        timestamp = now.utc.iso8601
        action["updated_at"] = timestamp if action.key?("updated_at")
        aggregate["updated_at"] = timestamp
        aggregate
      end

      def merge_receipts!(receipts, additions)
        changed = false
        additions.each do |key, value|
          if receipts.key?(key)
            unless receipts.fetch(key) == value
              raise InconsistentRecord, "action receipt #{key.inspect} is immutable"
            end
            next
          end

          receipts[key] = value
          changed = true
        end
        changed
      end

      def publication_continuation?(receipts)
        PublicationAttempt.phase_evidence?(receipts)
      end

      def normalize_creation_intent_receipt!(receipts, additions)
        return unless additions.key?("creation_intent")

        existing = receipts["creation_intent"]
        unless existing && (additions.fetch("creation_intent") == true || additions.fetch("creation_intent") == existing)
          raise InconsistentRecord, "creation intent must be recorded before an action outcome"
        end

        additions.delete("creation_intent")
      end

      def recompute_parent_state!(aggregate)
        actions = aggregate.fetch("actions")
        complete = actions.empty? || actions.all? { |action| action.fetch("terminal") }
        aggregate["complete"] = complete
        aggregate["state"] =
          if complete
            "complete"
          elsif actions.any? { |action| blocked_action?(action) }
            "blocked"
          else
            "acting"
          end
        aggregate
      end

      def blocked_action?(action)
        return false if action.fetch("terminal")
        return true if action.fetch("outcome") == "authority_revoked"

        Array(action["claims"]).last&.fetch("state", nil) == "released"
      end

      def diagnostic_generation(aggregate, kind)
        unless DIAGNOSTIC_ATTEMPT_KINDS.include?(kind)
          raise InconsistentRecord,
                "diagnostic attempt kind is invalid"
        end

        aggregate.fetch("attempts").filter_map do |attempt|
          attempt["generation"] if attempt["kind"] == kind
        end.max.to_i
      end

      def diagnostic_episode!(aggregate, kind, expected)
        episode = diagnostic_generation(aggregate, kind) + 1
        if expected && expected.to_i != episode
          raise InconsistentRecord,
                "diagnostic retry episode is stale"
        end

        episode
      end

      def append_job_transition!(aggregate, operation:, transition:,
                                 generation:, now:, outcome: "applied")
        unless generation.is_a?(Integer) && generation.positive?
          raise InconsistentRecord,
                "job transition generation must be a positive integer"
        end

        desired = transition_record(
          transition,
          generation: generation,
          now: now,
          outcome: outcome
        )
        intent_id = desired.fetch("intent_id")
        existing_attempt = aggregate.fetch("attempts").find do |attempt|
          Array(attempt["transitions"]).any? do |record|
            record["intent_id"] == intent_id
          end
        end
        if existing_attempt
          existing = existing_attempt.fetch("transitions").find do |record|
            record.fetch("intent_id") == intent_id
          end
          comparable_keys = TRANSITION_KEYS - [ "recorded_at" ]
          valid = existing_attempt["kind"] ==
                    JOB_TRANSITION_ATTEMPT_KIND &&
                  existing_attempt["operation"] == operation.to_s &&
                  existing_attempt["occurrence_id"] ==
                    aggregate.fetch("occurrence_id") &&
                  existing_attempt["generation"] == generation &&
                  existing.slice(*comparable_keys) ==
                    desired.slice(*comparable_keys)
          unless valid
            raise InconsistentRecord,
                  "refactor patrol transition identity conflicts"
          end
          return false
        end

        aggregate.fetch("attempts") << {
          "kind" => JOB_TRANSITION_ATTEMPT_KIND,
          "operation" => operation.to_s,
          "occurrence_id" => aggregate.fetch("occurrence_id"),
          "generation" => generation,
          "transitions" => [ desired ],
          "recorded_at" => now.utc.iso8601
        }
        true
      end

      def transition_record(value, generation:, now:, outcome: "applied")
        data = json_copy(value)
        error_code = outcome == "rejected" ?
          data.fetch("error_code").to_s : nil
        {
          "intent_id" => data.fetch("intent_id").to_s,
          "operation" => data.fetch("operation").to_s,
          "generation" => generation,
          "semantic_digest" => data.fetch("semantic_digest").to_s,
          "outcome" => outcome,
          "error_code" => error_code,
          "recorded_at" => now.utc.iso8601
        }
      rescue KeyError => e
        raise CorruptRecord,
              "refactor patrol transition is missing #{e.key.inspect}"
      end

      def append_transition!(records, transition)
        existing = records.find do |record|
          record.fetch("intent_id") == transition.fetch("intent_id")
        end
        if existing
          unless existing == transition
            raise InconsistentRecord,
                  "refactor patrol transition identity conflicts"
          end
          return existing
        end
        if records.size >= MAX_TRANSITIONS_PER_GENERATION
          raise InconsistentRecord,
                "refactor patrol transition history exceeds the bounded limit"
        end

        records << transition
        transition
      end

      def append_action_transition!(action, claim, transition, now,
                                    outcome: "applied")
        append_transition!(
          action.fetch("transitions"),
          transition_record(
            transition,
            generation: claim.fetch("generation"),
            now: now,
            outcome: outcome
          )
        )
      end

      def scheduling_key(aggregate)
        source = aggregate.fetch("source")
        merged_at = source["merged_at"] ? Time.iso8601(source.fetch("merged_at")).utc : Time.at(0).utc
        [ merged_at, source.fetch("number"), source.fetch("merge_sha"), aggregate.fetch("job_id") ]
      end

      def active_discovery_attempt(aggregate)
        aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] == DISCOVERY_ATTEMPT_KIND && ACTIVE_CLAIM_STATES.include?(attempt["state"])
        end
      end

      def claim_token(aggregate, attempt)
        {
          job_id: aggregate.fetch("job_id"), owner: attempt.fetch("owner"),
          generation: attempt.fetch("generation")
        }
      end

      def mutate_claim(token, now:)
        mutate_job(token.fetch(:job_id)) do |aggregate, path|
          attempt = active_discovery_attempt(aggregate)
          unless attempt && attempt["owner"] == token.fetch(:owner).to_s &&
                 attempt["generation"] == token.fetch(:generation).to_i
            raise StaleClaim.new("refactor patrol claim fence is stale", path: path)
          end
          if Time.iso8601(attempt.fetch("expires_at")) <= now
            raise StaleClaim.new("refactor patrol claim lease expired", path: path)
          end
          yield aggregate, attempt
        end
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol claim has invalid evidence (#{e.message})"
      end

      def mutate_job(job_id)
        prepare_schema_namespace!
        id = validate_id!(job_id)
        path = job_path(id)
        unless @job_files.job_exists?(id)
          raise RecordNotFound.new(
            "refactor patrol job not found",
            path: path
          )
        end
        @job_files.with_job_lock(id) do
          @job_query_index.with_registration(
            id,
            existing: true,
            migration_job_ids: method(:ordered_job_query_ids)
          ) do
            existing = read_job(id)
            aggregate = json_copy(existing)
            result = yield aggregate, path
            replacement, return_value = result.is_a?(Array) ? result : [ result, result ]
            validate_job!(replacement, path: path)
            validate_transition!(existing, replacement, path, action_api: true)
            atomic_write(path, replacement) unless replacement == existing
            return_value
          end
        end
      end

      def assert_matching_discovery_payload!(aggregate, payload, intermediate: false)
        unless payload.is_a?(Hash) && payload["schema"] == "hive-refactor-patrol" &&
               SUPPORTED_DISCOVERY_PAYLOAD_SCHEMA_VERSIONS.include?(payload["schema_version"]) && payload["ok"] == true &&
               [ true, false ].include?(payload["complete"]) &&
               payload["job_id"] == aggregate.fetch("job_id") &&
               payload["project"] == aggregate.dig("source", "registration") &&
               payload["project_root"] == project_root && payload["dry_run"] == false &&
               payload["analysis_sha"] == aggregate.fetch("analysis_sha") &&
               payload["source_pr"] == aggregate.fetch("source") &&
               payload["attempts"] == [] && payload["actions"] == []
          raise InconsistentRecord, "refactor patrol completion payload does not match its claimed job"
        end
        DISPOSITIONS.each { |name| payload.fetch(name) }
        errors = payload.fetch("review_errors")
        feature_results = payload.fetch("feature_results")
        unless errors.is_a?(Array) && errors.all? { |item| item.is_a?(Hash) } &&
               feature_results.is_a?(Array) && feature_results.all? { |item| item.is_a?(Hash) }
          raise InconsistentRecord, "refactor patrol feature progress is malformed"
        end
        ids = feature_results.map { |item| item["feature_id"] }
        if ids.any? { |id| id.to_s.empty? } || ids.uniq.size != ids.size ||
           payload.fetch("features_mapped") != feature_results.size
          raise InconsistentRecord, "refactor patrol feature progress is incomplete"
        end
        feature_results.each do |item|
          unless item.keys.sort == FEATURE_RESULT_KEYS.sort &&
                 [ true, false ].include?(item["complete"]) &&
                 item["thesis_ids"].is_a?(Array) && item["thesis_ids"].all? { |id| !id.to_s.empty? } &&
                 item["errors"].is_a?(Array) && item["errors"].all? { |error| error.is_a?(Hash) }
            raise InconsistentRecord, "refactor patrol feature result is malformed"
          end
          if item.fetch("complete") != item.fetch("errors").empty?
            raise InconsistentRecord, "refactor patrol feature completion contradicts its errors"
          end
        end
        unless feature_results.flat_map { |item| item.fetch("errors") } == errors
          raise InconsistentRecord, "refactor patrol review errors do not match feature progress"
        end
        payload.fetch("zero_reason")
        if intermediate
          unless payload.fetch("complete") == false && errors.empty? && feature_results.any? &&
                 feature_results.all? { |item| item.fetch("complete") } && payload["zero_reason"].nil?
            raise InconsistentRecord, "intermediate refactor patrol progress must contain only completed features"
          end
        elsif payload.fetch("complete")
          unless errors.empty? && feature_results.all? { |item| item.fetch("complete") }
            raise InconsistentRecord, "complete refactor patrol payload retains partial feature progress"
          end
        elsif !payload["zero_reason"].nil? || feature_results.empty?
          raise InconsistentRecord, "partial refactor patrol payload lacks retryable feature evidence"
        end
      rescue KeyError => e
        raise InconsistentRecord, "refactor patrol completion payload is missing #{e.key.inspect}"
      end

      def merge_discovery_progress!(aggregate, payload)
        incoming_results = payload.fetch("feature_results")
        prior_results = aggregate.fetch("feature_results")
        prior_by_feature = prior_results.to_h { |item| [ item.fetch("feature_id"), item ] }
        incoming_by_feature = incoming_results.to_h { |item| [ item.fetch("feature_id"), item ] }
        prior_by_feature.each do |feature_id, prior|
          unless incoming_by_feature[feature_id] == prior
            raise InconsistentRecord, "completed feature #{feature_id.inspect} changed during discovery resume"
          end
        end

        complete_results = incoming_results.select { |item| item.fetch("complete") }
        complete_feature_ids = complete_results.map { |item| item.fetch("feature_id") }
        incoming_dispositions = DISPOSITIONS.to_h do |name|
          items = payload.fetch(name).select { |item| complete_feature_ids.include?(item["feature_id"]) }
          [ name, items ]
        end
        thesis_ids_by_feature = DISPOSITIONS.flat_map { |name| incoming_dispositions.fetch(name) }
                                            .group_by { |item| item.fetch("feature_id") }
                                            .transform_values { |items| items.map { |item| item.fetch("id") }.sort }
        complete_results.each do |item|
          expected = thesis_ids_by_feature.fetch(item.fetch("feature_id"), [])
          unless item.fetch("thesis_ids").sort == expected
            raise InconsistentRecord, "feature thesis ids do not match discovery dispositions"
          end
        end

        existing_by_id = DISPOSITIONS.flat_map { |name| aggregate.dig("dispositions", name) }
                                     .to_h { |item| [ item.fetch("id"), item ] }
        incoming_dispositions.each do |name, items|
          items.each do |item|
            existing = existing_by_id[item.fetch("id")]
            if existing && existing != item
              raise InconsistentRecord, "completed thesis #{item.fetch('id').inspect} changed during discovery resume"
            end
            aggregate.dig("dispositions", name) << item unless existing
          end
        end
        aggregate["feature_results"] = complete_results.sort_by { |item| item.fetch("feature_id") }
      end

      def action_authorized_for?(aggregate)
        policy = aggregate.fetch("policy")
        (policy.fetch("auto_fix") && aggregate.dig("dispositions", "accepted").any?) ||
          (policy.fetch("issue_filing") && (
            aggregate.dig("dispositions", "accepted").any? ||
            aggregate.dig("dispositions", "flagged").any? { |item| item["admissible"] == true }
          ))
      end

      def source_from_manifest(manifest)
        unless manifest.is_a?(Hash) && manifest["schema"] == PrManifest::SCHEMA &&
               manifest["schema_version"] == PrManifest::SCHEMA_VERSION
          raise CorruptRecord, "refactor patrol intake requires a v2 PR manifest"
        end

        source = manifest.fetch("source")
        %w[url number repository registration base_branch base_sha merge_sha merged_at].each do |key|
          source.fetch(key)
        end
        source.merge(
          "changed_paths" => manifest.fetch("changed_paths"),
          "manifest_checksum" => manifest.fetch("manifest_checksum")
        )
      end

      def queued_aggregate(job_id:, source:, policy:, occurrence_id:,
                           intake_transition_id:, now:)
        timestamp = now.utc.iso8601
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "job_id" => job_id,
          "occurrence_id" => occurrence_id.to_s,
          "intake_transition_id" => intake_transition_id.to_s,
          "source" => source,
          "analysis_sha" => nil,
          "policy" => policy,
          "state" => "queued",
          "complete" => false,
          "dispositions" => DISPOSITIONS.to_h { |name| [ name, [] ] },
          "feature_results" => [],
          "review_errors" => [],
          "zero_reason" => nil,
          "attempts" => [],
          "actions" => [],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
      end

      def quarantine_job_source!(job_id, authoritative:, candidate:)
        digest = ::Digest::SHA256.hexdigest(JSON.generate(candidate.sort.to_h))
        relative = File.join(
          "quarantine",
          "jobs",
          "#{job_id}-#{digest}.json"
        )
        path = @job_files.absolute_path(relative)
        return path if @job_files.regular?(relative)

        evidence = {
          "schema" => "hive-refactor-patrol-job-intake-conflict",
          "schema_version" => 1,
          "job_id" => job_id,
          "reason" => "divergent_job_source",
          "authoritative_source" => authoritative,
          "candidate_source" => candidate
        }
        atomic_write(path, evidence)
      end

      def jobs_dir
        File.join(root, "jobs")
      end

      def job_path(job_id)
        @job_files.job_path(validate_id!(job_id))
      end

      def validate_id!(job_id)
        @record_validator.validate_id!(job_id)
      end

      def read_job_path(path, expected_job_id:)
        data = @job_files.read_json(
          @job_files.relative_path(path),
          max_bytes: JobStoreFiles::MAX_JOB_BYTES
        )
        raise CorruptRecord.new("refactor patrol job must contain a JSON object", path: path) unless data.is_a?(Hash)

        version = data["schema_version"]
        unless version.is_a?(Integer)
          raise CorruptRecord.new("refactor patrol job has no integer schema_version", path: path)
        end
        if version != SCHEMA_VERSION
          raise UnsupportedVersion.new("unsupported refactor patrol job schema_version #{version}", path: path)
        end

        validate_job!(data, path: path)
        unless data.fetch("job_id") == expected_job_id
          raise InconsistentRecord.new(
            "refactor patrol job id #{data.fetch('job_id').inspect} does not match filename #{expected_job_id.inspect}",
            path: path
          )
        end
        data
      rescue JSON::ParserError, EncodingError, SystemCallError, IOError => e
        raise CorruptRecord.new("cannot read refactor patrol job (#{e.class}: #{e.message})", path: path)
      end

      def validate_job!(data, path: nil)
        @record_validator.validate_job!(data, path: path)
      end

      def validate_transition!(existing, replacement, path, action_api: false)
        @record_validator.validate_transition!(
          existing, replacement, path, action_api: action_api
        )
      end

      def disposition_by_id(dispositions)
        @record_validator.disposition_by_id(dispositions)
      end

      def strict_hash!(value, required:, allowed:, label:, path:)
        @record_validator.strict_hash!(
          value, required: required, allowed: allowed, label: label, path: path
        )
      end

      def deep_sort(value)
        @record_validator.deep_sort(value)
      end

      def string_array!(value, label, path)
        @record_validator.string_array!(value, label, path)
      end

      def timestamp!(value, label, path)
        @record_validator.timestamp!(value, label, path)
      end

      def read_derived_index(path, schema:, collection:)
        relative = @job_files.relative_path(path)
        data = @job_files.read_json(relative, missing: true)
        return yield unless data
        unless data.is_a?(Hash) && data["schema"] == schema && data["schema_version"] == SCHEMA_VERSION &&
               data[collection].is_a?(Hash) && (data.keys - %w[schema schema_version] - [ collection ]).empty?
          return yield
        end
        data
      rescue JSON::ParserError, SystemCallError, IOError
        yield
      end

      def atomic_write(path, data)
        prepare_schema_namespace!
        @job_files.write_json(
          @job_files.relative_path(path),
          data
        )
        path
      end

      def prepare_schema_namespace!
        return true if @schema_namespace_ready

        self.class.ensure_schema_namespace!(
          @project_root, **@schema_options
        )
        @job_files.prepare!
        @schema_namespace_ready = true
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      rescue JSON::GeneratorError, TypeError => e
        raise CorruptRecord, "refactor patrol job is not JSON serializable (#{e.message})"
      end
    end
  end
end
