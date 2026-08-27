require "digest"
require "fileutils"
require "hive/atomic_file"
require "hive/git_ops"
require "hive/lock"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/publication_receipt"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/source_snapshot"
require "hive/patrol_fix/stage_transition"
require "hive/patrol_fix/task_manifest"
require "hive/task"
require "hive/task_capture"
require "hive/task_meta"

module Hive
  module PatrolFix
    # Executes the durable half of admission. AdmissionStore is the only
    # acknowledgement authority: it records completion only after the exact task
    # binding is durable, and a crash before that write safely replays the binding.
    class TaskMaterializer
      Result = Data.define(:task_folder, :slug, :generation, :created, :acknowledged)

      class Error < Hive::Error; end
      class InvalidAdmission < Error; end
      class MissingTask < Error; end

      def initialize(project_root:, hive_state:, store:, workflow_info:,
                     task_capture_factory: nil, git_ops: nil,
                     candidate_provider: nil, current_head: nil,
                     clock: -> { Time.now.utc })
        @project_root = File.expand_path(project_root)
        @hive_state = File.expand_path(hive_state)
        @store = store
        @workflow_info = workflow_info
        @task_capture_factory = task_capture_factory || ->(**args) { Hive::TaskCapture.new(**args) }
        @git_ops = git_ops || Hive::GitOps.new(@project_root)
        @candidate_provider = candidate_provider
        @current_head = current_head
        @clock = clock
      end

      def call(occurrence_id)
        created = false
        binding = nil
        task_folder = nil

        @store.with_materialization_lock do
          record = require_actionable_record!(occurrence_id)
          revalidate_candidate_set!(occurrence_id, record)
          if record["task"]
            binding = record.fetch("task")
            task_folder = find_bound_task!(binding)
          else
            task_folder, binding, created = materialize!(occurrence_id, record)
            @store.bind_task!(occurrence_id, task: binding, now: @clock.call)
          end
        end

        record = @store.fetch(occurrence_id)
        if record.fetch("status") == "acknowledged"
          return result(task_folder, binding, created: false, acknowledged: true)
        end
        @store.acknowledge!(occurrence_id, now: @clock.call)
        result(task_folder, binding, created: created, acknowledged: true)
      end

      private

      def require_actionable_record!(occurrence_id)
        record = @store.fetch(occurrence_id)
        raise InvalidAdmission, "admission occurrence is missing" unless record
        unless %w[decided materializing bound acknowledged].include?(record.fetch("status"))
          raise InvalidAdmission, "admission is not ready for materialization"
        end
        record
      end

      def revalidate_candidate_set!(occurrence_id, record)
        return unless @candidate_provider && @current_head
        return unless record.fetch("status") == "decided"

        snapshot = SourceSnapshot.new(record.fetch("source"))
        candidate_set = @candidate_provider.call(snapshot)
        candidates, inventory = if candidate_set.is_a?(Hash)
          [
            candidate_set.fetch("candidates"),
            {
              "count" => candidate_set.fetch("inventory_count"),
              "digest" => candidate_set.fetch("inventory_digest"),
              "context_digest" => candidate_set.fetch("context_digest"),
              "truncated" => candidate_set.fetch("truncated")
            }
          ]
        else
          [ Array(candidate_set), nil ]
        end
        current_digest = @store.candidate_digest(
          candidates, inventory: inventory, current_head: @current_head.call
        )
        return if current_digest == record.fetch("candidate_digest")

        @store.reset_decided_stale!(occurrence_id, now: @clock.call)
        raise AdmissionStore::StaleDecision,
              "admission candidate set changed before materialization"
      end

      def materialize!(occurrence_id, record)
        snapshot = SourceSnapshot.new(record.fetch("source"))
        if (intent = record["materialization_intent"])
          return resume_intent!(occurrence_id, record, snapshot, intent)
        end

        candidate = selected_candidate(record)
        if candidate&.fetch("kind") == "task"
          folder = find_patrol_fix_task!(candidate.fetch("identity"))
          return update_existing!(occurrence_id, record, snapshot, folder)
        end

        create_canonical!(occurrence_id, record, snapshot, candidate)
      end

      def resume_intent!(occurrence_id, record, snapshot, intent)
        candidate = selected_candidate(record)
        folder = locate_patrol_fix_task(intent.fetch("slug"))
        unless folder
          if candidate&.fetch("kind") == "task"
            raise MissingTask, "canonical Patrol Fix task is missing"
          end

          manifest = build_initial_manifest(intent.fetch("slug"), snapshot)
          assert_matching_intent!(
            intent, manifest, root_identity(record, snapshot, candidate)
          )
          capture = capture_task!(manifest, intent)
          persisted = TaskManifest.new(task_folder: capture.folder).read
          persist_publication_receipt!(capture.folder, persisted, record, snapshot)
          return [ capture.folder, task_binding(persisted), capture.created ]
        end

        if candidate&.fetch("kind") == "task"
          unless candidate.fetch("identity") == intent.fetch("slug")
            raise InvalidAdmission, "durable materialization intent changed canonical task"
          end
          expected = nil
          with_task_authority(folder, op: "patrol-fix-admit") do
            current = TaskManifest.new(task_folder: folder).read
            expected = merged_manifest(current, snapshot)
            assert_matching_intent!(intent, expected, "task:#{intent.fetch('slug')}")
            # Re-run the scoped commit even when the bytes already match. A hard
            # stop may have landed the atomic manifest write but not its commit.
            persist_task_artifacts!(folder, current: current, candidate: expected,
                                    record: record, snapshot: snapshot)
          end
          return [ folder, task_binding(expected), false ]
        end

        current = TaskManifest.new(task_folder: folder).read
        expected = build_initial_manifest(intent.fetch("slug"), snapshot)
        assert_matching_intent!(
          intent, expected, root_identity(record, snapshot, candidate)
        )
        unless current == expected
          raise InvalidAdmission, "durable materialization intent does not match its task bytes"
        end
        persist_publication_receipt!(folder, current, record, snapshot)
        [ folder, task_binding(current), false ]
      end

      def create_canonical!(occurrence_id, record, snapshot, candidate)
        slug = canonical_slug(snapshot, candidate)
        manifest = build_initial_manifest(slug, snapshot)
        intent = materialization_intent(manifest, root_identity(record, snapshot, candidate))
        @store.begin_materialization!(occurrence_id, intent: intent, now: @clock.call)
        capture = capture_task!(manifest, intent)
        persisted = TaskManifest.new(task_folder: capture.folder).read
        persist_publication_receipt!(capture.folder, persisted, record, snapshot)
        [ capture.folder, task_binding(persisted), capture.created ]
      end

      def capture_task!(manifest, intent)
        @task_capture_factory.call(
          project_root: @project_root,
          hive_state: @hive_state,
          workflow_info: @workflow_info,
          slug: manifest.dig("task", "slug"),
          state_bytes: PatrolFix.canonical_json(manifest),
          idempotency_key: intent.fetch("idempotency_key"),
          input_fingerprint: intent.fetch("input_fingerprint")
        ).call
      end

      def update_existing!(occurrence_id, record, snapshot, folder)
        binding = nil
        with_task_authority(folder, op: "patrol-fix-admit") do
          current = TaskManifest.new(task_folder: folder).read
          candidate = merged_manifest(current, snapshot)
          intent = materialization_intent(candidate, "task:#{File.basename(folder)}")
          @store.begin_materialization!(occurrence_id, intent: intent, now: @clock.call)
          persist_task_artifacts!(folder, current: current, candidate: candidate,
                                  record: record, snapshot: snapshot)
          binding = task_binding(candidate)
        end
        [ folder, binding, false ]
      end

      def persist_task_artifacts!(folder, current:, candidate:, record:, snapshot:)
        manifest_store = TaskManifest.new(task_folder: folder)
        originals = capture_originals(manifest_store.path, ReceiptStore.new(task_folder: folder).path)
        with_commit_rollback(folder, originals) do
          manifest_store.write!(candidate) unless current == candidate
          append_publication_receipt!(folder, candidate, record, snapshot)
          @git_ops.hive_commit(
            stage_name: File.basename(File.dirname(folder)), slug: File.basename(folder),
            action: "admission updated"
          )
        end
      end

      def persist_publication_receipt!(folder, manifest, record, snapshot)
        return unless exact_pull_request(record, snapshot)

        with_task_authority(folder, op: "patrol-fix-admit") do
          current = TaskManifest.new(task_folder: folder).read
          unless current == manifest
            raise InvalidAdmission, "task generation changed before publication provenance was linked"
          end
          originals = capture_originals(ReceiptStore.new(task_folder: folder).path)
          with_commit_rollback(folder, originals) do
            appended = append_publication_receipt!(folder, manifest, record, snapshot)
            @git_ops.hive_commit(
              stage_name: File.basename(File.dirname(folder)), slug: File.basename(folder),
              action: "publication linked"
            ) if appended
          end
        end
      end

      def with_task_authority(folder, op:)
        task = Hive::Task.new(folder)
        Hive::PatrolFix::StageTransition.with_lock(task) do
          Hive::Lock.with_task_lock(
            folder, slug: File.basename(folder), op: op, create: false
          ) { yield }
        end
      end

      def append_publication_receipt!(folder, manifest, record, snapshot)
        pull_request = exact_pull_request(record, snapshot)
        return false unless pull_request

        receipt = publication_receipt(manifest, pull_request)
        store = ReceiptStore.new(task_folder: folder)
        existed = store.read_all.any? { |entry| entry.fetch("receipt_id") == receipt.fetch("receipt_id") }
        store.append!(receipt)
        !existed
      end

      def selected_candidate(record)
        return unless record.dig("decision", "decision") == "same_root"

        identity = record.dig("decision", "candidate_identity")
        record.fetch("candidates").find { |candidate| candidate.fetch("identity") == identity } ||
          raise(AdmissionStore::StaleDecision, "selected admission candidate is no longer current")
      end

      def find_bound_task!(binding)
        folder = find_patrol_fix_task!(binding.fetch("slug"))
        manifest = TaskManifest.new(task_folder: folder).read
        unless task_binding(manifest) == binding
          raise InvalidAdmission, "admission binding no longer matches task evidence"
        end
        folder
      end

      def find_patrol_fix_task!(slug)
        locate_patrol_fix_task(slug) ||
          raise(MissingTask, "canonical Patrol Fix task is missing")
      end

      def locate_patrol_fix_task(slug)
        matches = Dir.glob(File.join(@hive_state, "stages", "*", slug.to_s)).select do |folder|
          next false unless File.directory?(folder)
          admission = Hive::TaskMeta.read_for_admission(folder)
          raise MissingTask, "candidate task metadata is not readable" unless admission.status == :ok
          admission.data[:workflow] == WORKFLOW_ID.to_s
        end
        raise MissingTask, "canonical Patrol Fix task identity is ambiguous" if matches.length > 1
        matches.first unless matches.empty?
      end

      def build_initial_manifest(slug, snapshot)
        {
          "schema" => TaskManifest::SCHEMA,
          "schema_version" => TaskManifest::SCHEMA_VERSION,
          "task" => { "slug" => slug, "generation" => 1 },
          "evidence_revision" => { "generation" => 1, "digest" => snapshot.evidence_digest },
          "target_revision" => snapshot.to_h.fetch("target_revision"),
          "sources" => [ snapshot.source_manifest_entry ],
          "aliases" => aliases_for(snapshot),
          "relations" => { "successor" => nil, "issues" => snapshot.to_h.fetch("external_issues") }
        }
      end

      def merged_manifest(current, snapshot)
        candidate = PatrolFix.deep_copy(current)
        source = snapshot.source_manifest_entry
        index = candidate.fetch("sources").index do |entry|
          entry.values_at("engine", "identity") == source.values_at("engine", "identity")
        end
        previous_digest = @store.prior_source_evidence(
          task_slug: current.dig("task", "slug"), engine: source.fetch("engine"),
          identity: source.fetch("identity")
        )
        if index.nil?
          candidate.fetch("sources") << source
        elsif previous_digest != snapshot.evidence_digest && candidate.fetch("sources")[index] != source
          generation = current.dig("task", "generation") + 1
          candidate["task"]["generation"] = generation
          candidate["evidence_revision"] = {
            "generation" => generation, "digest" => snapshot.evidence_digest
          }
          candidate["target_revision"] = snapshot.to_h.fetch("target_revision")
          candidate.fetch("sources")[index] = source
        end
        candidate["aliases"] = union(candidate.fetch("aliases"), aliases_for(snapshot))
        candidate["relations"]["issues"] = union(
          candidate.dig("relations", "issues"), snapshot.to_h.fetch("external_issues")
        )
        candidate
      end

      def aliases_for(snapshot)
        kind = snapshot.to_h.fetch("engine") == "ordinary_patrol" ?
          "ordinary_finding" : "architecture_thesis"
        union(
          [ { "kind" => kind, "value" => snapshot.to_h.fetch("identity") } ],
          snapshot.to_h.fetch("aliases")
        )
      end

      def union(left, right)
        (Array(left) + Array(right)).uniq.sort_by { |entry| PatrolFix.canonical_json(entry) }
      end

      def root_identity(record, snapshot, candidate)
        if candidate
          "#{candidate.fetch('kind')}:#{candidate.fetch('identity')}"
        else
          "#{snapshot.to_h.fetch('engine')}:#{snapshot.to_h.fetch('identity')}"
        end
      end

      def canonical_slug(snapshot, candidate)
        digest = Digest::SHA256.hexdigest(root_identity({}, snapshot, candidate))[0, 12]
        stem = snapshot.to_h.fetch("title").downcase
          .gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 48].to_s.sub(/-+\z/, "")
        stem = "fix-#{stem}" unless stem.match?(/\A[a-z]/)
        stem = "patrol-fix" if stem.length < 2
        "#{stem}-#{digest}"[0, 64].sub(/-+\z/, "")
      end

      def materialization_intent(manifest, root_identity)
        bytes = PatrolFix.canonical_json(manifest)
        root_digest = Digest::SHA256.hexdigest(root_identity)
        {
          "idempotency_key" => "patrol-fix:#{root_digest}",
          "input_fingerprint" => Digest::SHA256.hexdigest(bytes),
          "slug" => manifest.dig("task", "slug"),
          "generation" => manifest.dig("task", "generation"),
          "evidence_digest" => manifest.dig("evidence_revision", "digest")
        }
      end

      def assert_matching_intent!(intent, manifest, root_identity)
        return if materialization_intent(manifest, root_identity) == intent

        raise InvalidAdmission, "durable materialization intent does not match task bytes"
      end

      def task_binding(manifest)
        {
          "slug" => manifest.dig("task", "slug"),
          "generation" => manifest.dig("task", "generation"),
          "evidence_digest" => manifest.dig("evidence_revision", "digest")
        }
      end

      def exact_pull_request(record, snapshot)
        return unless record.dig("decision", "decision") == "same_root"
        candidate = selected_candidate(record)
        return unless candidate.fetch("kind") == "pull_request"
        identity = candidate.fetch("identity")
        snapshot.to_h.fetch("existing_pull_requests").find do |pull_request|
          pull_request.fetch("id") == identity || pull_request.fetch("url") == identity
        end
      end

      def publication_receipt(manifest, pull_request)
        PublicationReceipt.adopt(
          task: manifest.fetch("task"),
          evidence_revision: manifest.fetch("evidence_revision"),
          payload: pull_request
        )
      end

      def capture_originals(*paths)
        paths.to_h { |path| [ path, File.file?(path) ? File.binread(path) : nil ] }
      end

      def restore_originals!(originals)
        originals.each do |path, bytes|
          if bytes
            Hive::AtomicFile.write(path, bytes, mode: 0o600)
          else
            File.delete(path) if File.exist?(path)
          end
        end
      end

      def with_commit_rollback(folder, originals)
        Hive::Lock.with_commit_lock(@hive_state) do
          yield
        rescue StandardError, Interrupt
          restore_originals!(originals)
          reset_task_index!(folder)
          raise
        end
      end

      def reset_task_index!(folder)
        relative = folder.delete_prefix("#{@hive_state}/")
        @git_ops.run_git!("-C", @hive_state, "reset", "-q", "HEAD", "--", relative)
      end

      def result(folder, binding, created:, acknowledged:)
        Result.new(task_folder: folder, slug: binding.fetch("slug"),
                   generation: binding.fetch("generation"), created: created,
                   acknowledged: acknowledged)
      end
    end
  end
end
