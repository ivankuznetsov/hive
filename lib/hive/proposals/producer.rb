require "digest"
require "securerandom"
require "hive/attempts/api"
require "hive/config"
require "hive/git_ops"
require "hive/proposals/ingestor"
require "hive/proposals/evaluator_authority"
require "hive/task_activity"
require "hive/task_journal"

module Hive
  module Proposals
    ProductionResult = Data.define(:proposal_id, :source_event_id, :source_commit, :ingestion) do
      def to_h
        {
          "proposal_id" => proposal_id, "source_event_id" => source_event_id,
          "source_commit" => source_commit, "ingestion" => ingestion.to_h
        }
      end
    end

    # Owns the event-first boundary for both CLI and future workflow callers.
    # The task/activity/inbox commit and canonical ingestion commit are
    # independent rollback scopes by design.
    class Producer
      class << self
        def for_task(project_root:, task:, attempts: Hive::Attempts::API.new,
                     git_ops: Hive::GitOps.new(project_root), config: nil)
          activity = Hive::TaskActivity.for_task(task, attempt_store: attempts)
          raise Unauthorized, "proposal command requires a durable task attempt" unless activity

          attempt = attempts.fetch(activity.binding.fetch("attempt_id"))
          raise Unauthorized, "proposal command has no admitted attempt" unless attempt

          new(
            project_root:, activity:, attempt:, git_ops:,
            config: config || Hive::Config.load(project_root)
          )
        end
      end

      def initialize(project_root:, activity:, attempt:, git_ops: Hive::GitOps.new(project_root),
                     config: nil, source_store: nil, store: nil, ingestor: nil,
                     proposal_id_generator: -> { "prp-#{SecureRandom.uuid}" },
                     source_id_generator: -> { SecureRandom.uuid }, clock: -> { Time.now.utc })
        @project_root = File.expand_path(project_root)
        @activity = activity
        @attempt = attempt
        @git_ops = git_ops
        @config = config || Hive::Config::DEFAULTS
        @proposal_id_generator = proposal_id_generator
        @source_id_generator = source_id_generator
        @clock = clock
        proposal_root = File.join(@git_ops.hive_state_path, "proposals", "v1")
        limits = @config.dig("proposals", "limits") || {}
        @source_store = source_store || SourceEventStore.new(root: proposal_root, limits:, clock:)
        @store = store || Store.new(root: proposal_root)
        @ingestor = ingestor || Ingestor.new(
          source_store: @source_store, store: @store, git_ops: @git_ops
        )
        @proposal_binding = SourceEvent.normalize_proposal_binding(extract_proposal_binding)
      end

      def submit(proposed_change:, motivation:, evidence:, lineage: {},
                 artifact: nil, source_event_id: nil, idempotency_key: nil)
        source_event_id = resolve_source_event_id(source_event_id, idempotency_key)
        existing = @source_store.fetch(source_event_id)
        proposal_id = @proposal_binding.dig("subject", "proposal_id") ||
          existing&.proposal_id || @proposal_id_generator.call
        event = SourceEvent.submission(
          source_event_id:,
          proposal_id:, proposal_binding: @proposal_binding,
          task_binding: task_binding,
          proposed_change:, motivation:, evidence:, lineage:,
          artifact:,
          created_at: existing&.to_h&.fetch("created_at") || @clock.call
        )
        produce!(event)
      end

      def evaluate(method:, result:, rationale:, evidence:, links: [],
                   artifact: nil, source_event_id: nil, idempotency_key: nil)
        proposal_id = @proposal_binding.dig("subject", "proposal_id")
        raise Unauthorized, "proposal evaluation attempt is not bound to a proposal ID" unless proposal_id

        source_event_id = resolve_source_event_id(source_event_id, idempotency_key)
        existing = @source_store.fetch(source_event_id)
        ensure_evaluator_currently_authorized! unless existing && committed_source_event?(existing)
        event = SourceEvent.evaluation(
          source_event_id:,
          proposal_id:, proposal_binding: @proposal_binding,
          task_binding: task_binding, method:, result:, rationale:, evidence:, links:,
          artifact:,
          created_at: existing&.to_h&.fetch("created_at") || @clock.call
        )
        produce!(event)
      end

      private

      def produce!(event)
        commit_source_receipt!(event)
        receipt_path = Proposals.hive_state_relative_path(
          @git_ops, @source_store.paths_for_admission(event.source_event_id).first,
          label: "proposal producer path"
        )
        source_commit = @git_ops.hive_state_commit_for_path(receipt_path)
        unless source_commit && committed_receipt_matches?(event, source_commit, receipt_path)
          raise SourceUnavailable, "proposal source receipt was not durably committed"
        end
        ingestion = @ingestor.ingest!(event.source_event_id, source_commit:)
        ProductionResult.new(
          proposal_id: event.proposal_id, source_event_id: event.source_event_id,
          source_commit:, ingestion:
        )
      end

      def commit_source_receipt!(event)
        paths = @source_store.paths_for_admission(event.source_event_id)
        relative_paths = paths.map do |path|
          Proposals.hive_state_relative_path(@git_ops, path, label: "proposal producer path")
        end
        snapshot = nil
        Hive::Lock.with_commit_lock(@git_ops.hive_state_path) do
          ensure_safe_task_journal!
          snapshot = Ingestor::PathSnapshot.capture(snapshot_roots(paths))
          index_snapshot = Proposals::GitIndexSnapshot.capture(@git_ops)
          begin
            @git_ops.hive_commit(
              stage_name: task_binding.fetch("stage"),
              slug: task_binding.fetch("task_slug"),
              action: "admitted proposal source #{event.source_event_id}",
              additional_pathspecs: relative_paths,
              before_stage: lambda do
                @source_store.admit!(event)
                record_activity!(event)
              end
            )
          rescue StandardError => error
            snapshot.restore!
            index_snapshot.restore!
            raise error
          end
        end
      end

      def record_activity!(event)
        @activity.record(
          kind: "proposal_source_recorded", operation_id: event.source_event_id,
          correlation_id: event.source_event_id, reason: "proposal_source_admitted",
          source: "proposal_service",
          payload: {
            "source_event_id" => event.source_event_id,
            "source_event_digest" => event.digest,
            "proposal_id" => event.proposal_id, "source_kind" => event.kind
          }
        )
      end

      def task_binding
        @task_binding ||= begin
          binding = Proposals.stringify(@activity.binding)
          task = binding.fetch("task")
          project = @attempt["project"] if @attempt.respond_to?(:data)
          project = File.basename(@project_root) if project.to_s.empty?
          SourceEvent.normalize_task_binding(
            "project" => project,
            "task_id" => task.fetch("id"), "task_slug" => task.fetch("slug"),
            "workflow_id" => binding.fetch("workflow"), "stage" => binding.fetch("stage"),
            "task_generation" => binding.fetch("task_generation"),
            "ownership_generation" => binding.fetch("ownership_generation"),
            "attempt_id" => binding.fetch("attempt_id")
          )
        end
      end

      def extract_proposal_binding
        value = if @attempt.respond_to?(:proposal_binding)
          @attempt.proposal_binding
        elsif @attempt.respond_to?(:[])
          @attempt.dig("subject", "proposal")
        end
        raise Unauthorized, "durable attempt has no proposal subject binding" unless value
        value
      end

      def resolve_source_event_id(explicit, idempotency_key)
        return Proposals.source_event_id!(explicit) if explicit

        seed = idempotency_key || @source_id_generator.call
        raise InvalidRecord, "proposal source idempotency key is empty" if seed.to_s.empty?
        "pse-#{Digest::SHA256.hexdigest("hive-proposal-source-v1\0#{seed}")}"
      end

      def committed_receipt_matches?(event, source_commit, receipt_path)
        bytes = @git_ops.read_hive_state_blob_at(
          source_commit, receipt_path, max_bytes: SourceEventStore::MAX_FILE_BYTES + 1
        )
        bytes == Proposals.canonical(event.to_h)
      end

      def committed_source_event?(event)
        receipt_path = Proposals.hive_state_relative_path(
          @git_ops, @source_store.paths_for_admission(event.source_event_id).first,
          label: "proposal producer path"
        )
        commit = @git_ops.hive_state_commit_for_path(receipt_path)
        commit && committed_receipt_matches?(event, commit, receipt_path)
      end

      def ensure_evaluator_currently_authorized!
        evaluator = @proposal_binding.fetch("evaluator")
        raise Unauthorized, "proposal evaluation requires an admitted evaluator binding" unless evaluator

        current = EvaluatorAuthority.new(@config).bind!(
          identity: evaluator.fetch("id"), workflow: task_binding.fetch("workflow_id"),
          stage: task_binding.fetch("stage"), agent_profile: attempt_provider
        )
        return if current.fetch("id") == evaluator.fetch("id")

        raise Unauthorized, "proposal evaluator is no longer configured"
      end

      def attempt_provider
        @attempt["provider"] if @attempt.respond_to?(:[])
      end

      def snapshot_roots(source_paths)
        journal = File.join(@activity.task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
        (source_paths + [ journal ]).uniq
      end

      def ensure_safe_task_journal!
        task_folder = File.expand_path(@activity.task_folder)
        relative = Proposals.hive_state_relative_path(
          @git_ops, task_folder, label: "proposal task folder"
        )
        current = File.expand_path(@git_ops.hive_state_path)
        relative.split(File::SEPARATOR).each do |segment|
          current = File.join(current, segment)
          status = File.lstat(current)
          unless status.directory? && !status.symlink?
            raise Error, "proposal task journal parent is unsafe"
          end
        end
        [ Hive::TaskJournal::JOURNAL_BASENAME, Hive::TaskJournal::LOCK_BASENAME ].each do |name|
          status = File.lstat(File.join(task_folder, name))
          unless status.file? && !status.symlink?
            raise Error, "proposal task journal path is unsafe"
          end
        rescue Errno::ENOENT
          nil
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error, "proposal task journal parent is unsafe"
      end
    end
  end
end
