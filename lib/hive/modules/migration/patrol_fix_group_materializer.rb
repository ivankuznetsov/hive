require "digest"
require "fileutils"
require "hive/git_ops"
require "hive/lock"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/stage_transition"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/task_materializer"
require "hive/task"
require "hive/workflows/registry"

module Hive
  module Modules
    module Migration
      # Applies one U8 semantic group through the existing AdmissionStore and
      # TaskMaterializer. Every source is re-read before the first task effect;
      # admission acknowledgements are internal new-authority checkpoints and
      # the legacy source acknowledgement remains Applier's final operation.
      class PatrolFixGroupMaterializer
        class Error < Hive::Error; end

        def initialize(project_root:, hive_state_path:, manifest:, source_authority:,
                       admission_store: nil, task_materializer_factory: nil,
                       git_ops: nil, clock: -> { Time.now.utc })
          @project_root = File.expand_path(project_root)
          @hive_state_path = File.expand_path(hive_state_path)
          @manifest = manifest
          @source_authority = source_authority
          @admission_store = admission_store || Hive::PatrolFix::AdmissionStore.new(
            root: File.join(@hive_state_path, "patrol-fix", "admissions")
          )
          @task_materializer_factory = task_materializer_factory ||
            method(:build_task_materializer)
          @git_ops = git_ops || Hive::GitOps.new(@project_root)
          @clock = clock
        end

        def call(group)
          snapshots = group.fetch("members").to_h do |member|
            [ member, @source_authority.snapshot_for(member, group: group) ]
          end
          binding = nil
          folder = nil
          group.fetch("members").each_with_index do |member, index|
            snapshot = snapshots.fetch(member)
            occurrence_id = occurrence_id(group.fetch("group_id"), member)
            decide!(occurrence_id, snapshot, group, binding, first: index.zero?)
            result = @task_materializer_factory.call(
              store: @admission_store,
              source_acknowledger: lambda do |_record, _task|
                raise Error, "migration source acknowledgement ran before group completion"
              end
            ).call(occurrence_id, acknowledge: false)
            folder = result.task_folder
            binding = {
              "slug" => result.slug, "generation" => result.generation,
              "evidence_digest" => Hive::PatrolFix::TaskManifest.new(
                task_folder: folder
              ).read.dig("evidence_revision", "digest")
            }
          end
          raise Error, "migration semantic group produced no task" unless binding && folder

          import_done!(folder, binding) if
            group.dig("canonical_decision", "route") == "done_existing_pr"
          binding
        end

        def record_source_acknowledgement!(member, task:, receipt_id:, now: @clock.call)
          group = @manifest.to_h.fetch("semantic_groups").find do |candidate|
            candidate.fetch("members").include?(member)
          end
          raise Error, "migration source member has no semantic group" unless group

          occurrence = occurrence_id(group.fetch("group_id"), member)
          record = @admission_store.fetch(occurrence)
          unless record && record.fetch("task") == task &&
                 %w[bound acknowledged].include?(record.fetch("status"))
            raise Error, "migration admission is not bound to the canonical task"
          end
          @admission_store.acknowledge!(
            occurrence, source_receipt_id: receipt_id, now: now
          )
          receipt_id
        end

        private

        def decide!(occurrence_id, snapshot, group, binding, first:)
          record = @admission_store.fetch(occurrence_id) || @admission_store.reserve!(
            occurrence_id: occurrence_id, snapshot: snapshot, now: @clock.call
          )
          return if %w[decided materializing bound acknowledged].include?(record.fetch("status"))

          candidates, decision, identity = decision_for(
            snapshot, group, binding, first: first
          )
          prepared = @admission_store.prepare_decision!(
            occurrence_id, candidates: candidates,
            current_head: snapshot.to_h.fetch("target_revision"), now: @clock.call
          )
          @admission_store.record_decision!(
            occurrence_id, candidate_digest: prepared.fetch("candidate_digest"),
            reservation_id: prepared.dig("decision_reservation", "reservation_id"),
            decision: decision, candidate_identity: identity,
            rationale: "U8 cutover manifest canonical semantic group",
            evidence: [ "Bound to #{group.fetch('candidate_set_digest')}" ],
            model_receipt: "migration-manifest:#{Digest::SHA256.hexdigest(@manifest.canonical_bytes)[0, 32]}",
            now: @clock.call
          )
        end

        def decision_for(snapshot, group, binding, first:)
          if binding
            candidate = task_candidate(binding)
            return [ [ candidate ], "same_root", candidate.fetch("identity") ]
          end
          route = group.dig("canonical_decision", "route")
          identity = group.dig("canonical_decision", "canonical_identity")
          case route
          when "retain_patrol_fix_task"
            candidate = current_task_candidate(identity)
            [ [ candidate ], "same_root", candidate.fetch("identity") ]
          when "done_existing_pr"
            publication = snapshot.to_h.fetch("existing_pull_requests").find do |entry|
              entry.fetch("id") == identity || entry.fetch("url") == identity
            end
            raise Error, "exact migration publication observation is missing" unless publication

            candidate = {
              "kind" => "pull_request", "identity" => identity,
              "evidence_digest" => Digest::SHA256.hexdigest(
                Hive::PatrolFix.canonical_json(publication)
              ),
              "target_revision" => snapshot.to_h.fetch("target_revision")
            }
            [ [ candidate ], "same_root", identity ]
          else
            raise Error, "migration semantic group cannot attach without a canonical task" unless first

            [ [], "distinct", nil ]
          end
        end

        def task_candidate(binding)
          manifest = current_task_manifest(binding.fetch("slug"))
          {
            "kind" => "task", "identity" => binding.fetch("slug"),
            "evidence_digest" => manifest.dig("evidence_revision", "digest"),
            "target_revision" => manifest.fetch("target_revision")
          }
        end

        def current_task_candidate(identity)
          task_candidate("slug" => identity.to_s)
        end

        def current_task_manifest(slug)
          matches = Dir.glob(File.join(@hive_state_path, "stages", "*", slug.to_s)).select do |path|
            File.directory?(path)
          end
          raise Error, "canonical Patrol-fix task is missing or ambiguous" unless matches.one?

          Hive::PatrolFix::TaskManifest.new(task_folder: matches.first).read
        end

        def build_task_materializer(store:, source_acknowledger:)
          Hive::PatrolFix::TaskMaterializer.new(
            project_root: @project_root, hive_state: @hive_state_path,
            store: store,
            workflow_info: {
              descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
              pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
            },
            source_acknowledger: source_acknowledger,
            git_ops: @git_ops, clock: @clock
          )
        end

        def import_done!(folder, binding)
          current = locate_task(binding.fetch("slug"))
          unless publication_receipt?(current, binding)
            raise Error, "exact migration publication is not durably bound"
          end

          task = Hive::Task.new(current)
          Hive::PatrolFix::StageTransition.with_lock(task) do
            source_stage = File.basename(File.dirname(current))
            destination = File.join(@hive_state_path, "stages", "6-done", binding.fetch("slug"))
            Hive::Lock.with_commit_lock(@hive_state_path) do
              unless source_stage == "6-done"
                unless current == folder
                  raise Error, "migration task moved before publication import"
                end
                FileUtils.mkdir_p(File.dirname(destination))
                if File.exist?(destination)
                  raise Error, "migration done destination already exists"
                end
                File.rename(current, destination)
                Hive::AtomicFile.fsync_directory(File.dirname(current))
                Hive::AtomicFile.fsync_directory(File.dirname(destination))
              end
              commit_done!(source_stage, binding.fetch("slug"))
            end
          end
        rescue SystemCallError, IOError => error
          raise Error, "migration task stage import failed: #{error.message}"
        end

        def commit_done!(_source_stage, slug)
          paths = Hive::PatrolFix::Projection::STAGE_DIRS.map do |stage|
            File.join("stages", stage, slug)
          end
          @git_ops.hive_commit(
            stage_name: "6-done", slug: slug,
            action: "existing publication imported", pathspecs: paths
          )
        end

        def publication_receipt?(folder, binding)
          Hive::PatrolFix::ReceiptStore.new(task_folder: folder).read_all.any? do |receipt|
            receipt.fetch("kind") == "publication" &&
              receipt.fetch("task") == {
                "slug" => binding.fetch("slug"),
                "generation" => binding.fetch("generation")
              } &&
              receipt.dig("evidence_revision", "digest") == binding.fetch("evidence_digest")
          end
        end

        def locate_task(slug)
          matches = Dir.glob(File.join(@hive_state_path, "stages", "*", slug)).select do |path|
            File.directory?(path)
          end
          raise Error, "canonical Patrol-fix task is missing or ambiguous" unless matches.one?
          matches.first
        end

        def occurrence_id(group_id, member)
          "migration-#{Digest::SHA256.hexdigest([ group_id, member ].join("\0"))}"
        end
      end
    end
  end
end
