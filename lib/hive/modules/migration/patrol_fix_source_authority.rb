require "digest"
require "hive/patrol/finding"
require "hive/patrol_fix"
require "hive/patrol_fix/migration/inventory"
require "hive/patrol_fix/source_snapshot"
require "hive/patrol_fix/task_manifest"

module Hive
  module Modules
    module Migration
      # Source-owned U9 edge. It re-reads immutable ordinary findings and
      # Architecture v4 jobs before translating them to SourceSnapshot. The
      # U8 manifest is only a binding; it is never used as task content.
      class PatrolFixSourceAuthority
        class Error < Hive::Error; end
        class StaleSource < Error; end

        attr_reader :ordinary_store, :architecture_store

        def initialize(ordinary_store:, architecture_store:, manifest:,
                       canonical_action_catalog: nil)
          @ordinary_store = ordinary_store
          @architecture_store = architecture_store
          @manifest = manifest
          @canonical_action_catalog = canonical_action_catalog
          @candidates = manifest.to_h.dig("inventory", "candidates").to_h do |candidate|
            [ source_ref(candidate), candidate ]
          end
        end

        def inventory
          Hive::PatrolFix::Migration::Inventory.new(
            source_ports: [
              ordinary_store.patrol_fix_migration_inventory,
              architecture_store.patrol_fix_migration_inventory(
                canonical_action_catalog: @canonical_action_catalog
              )
            ]
          ).capture
        end

        def snapshot_for(member, group: nil)
          expected = candidate_for(member)
          snapshot = case expected.fetch("source_kind")
          when "ordinary_finding"
            ordinary_snapshot(expected)
          when "architecture_finding"
            architecture_snapshot(expected)
          else
            raise StaleSource,
                  "blocked migration source #{member} has no materializable record"
          end
          augment_observations(snapshot, group)
        end

        def acknowledge(member, outcome, group: nil, now: Time.now.utc)
          expected = candidate_for(member)
          if outcome["route"].to_s.start_with?("blocked_")
            return blocked_acknowledgement(member, outcome)
          end

          snapshot = snapshot_for(member, group: group)
          outbox = outbox_for(expected.fetch("source_kind"))
          occurrence_id = outbox.migration_occurrence_id(snapshot)
          outbox.publish_migration_snapshot!(snapshot, accepted_at: now)
          receipt = outbox.acknowledge!(
            occurrence_id: occurrence_id,
            admission_id: migration_admission_id(group, member),
            task: outcome, now: now
          )
          outbox.settle!(occurrence_id: occurrence_id, now: now)
          receipt
        end

        def verify(manifest:, state:, inventory:)
          groups = manifest.fetch("semantic_groups")
          acknowledgements = state.fetch("groups").sum do |_id, group|
            group.fetch("acknowledgements").length
          end
          expected = manifest.fetch("dispositions").length
          unless acknowledgements == expected
            raise StaleSource, "Patrol-fix migration source acknowledgements are incomplete"
          end
          groups.each do |group|
            progress = state.dig("groups", group.fetch("group_id")) || {}
            unless progress.fetch("status", nil) == "complete" &&
                   progress.fetch("acknowledgements", {}).keys.sort == group.fetch("members").sort
              raise StaleSource, "Patrol-fix migration semantic group is incomplete"
            end
            if group.dig("canonical_decision", "route").to_s.start_with?("blocked_")
              verify_blocking_dispositions!(group, progress)
              next
            end

            verify_task!(progress.fetch("task"))
            group.fetch("members").each do |member|
              verify_source_acknowledgement!(
                member, progress.fetch("task"),
                progress.fetch("acknowledgements").fetch(member), group
              )
            end
          end
          {
            "inventory_count" => inventory.fetch("count"),
            "inventory_root_digest" => inventory.fetch("root_digest"),
            "disposition_count" => expected,
            "completed_group_count" => groups.length,
            "authority_digest" => Digest::SHA256.hexdigest(
              Hive::PatrolFix.canonical_json(
                state.fetch("groups").transform_values do |group|
                  group.slice("task", "acknowledgements")
                end
              )
            )
          }
        end

        private

        def candidate_for(member)
          @candidates.fetch(member.to_s) do
            raise StaleSource, "migration manifest member is unknown"
          end
        end

        def ordinary_snapshot(expected)
          entry = ordinary_store.patrol_fix_migration_source(expected.fetch("source_id"))
          assert_entry_binding!(entry, expected)
          finding = Hive::Patrol::Finding.from_h(entry.fetch("record"))
          ordinary_store.patrol_fix_admission_outbox.migration_snapshot(finding)
        rescue KeyError, ArgumentError => error
          raise StaleSource, "ordinary migration source is invalid: #{error.message}"
        end

        def architecture_snapshot(expected)
          job_id, thesis_id = expected.fetch("source_id").split(":", 2)
          raise StaleSource, "Architecture migration source identity is invalid" unless thesis_id

          entry = architecture_store.patrol_fix_migration_source(job_id)
          expected_digest = Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
            "job_digest" => entry.fetch("canonical_digest"),
            "source_identity" => expected.fetch("source_id")
          ))
          unless entry.fetch("source_schema") == expected.fetch("source_schema") &&
                 expected_digest == expected.fetch("canonical_digest")
            raise StaleSource,
                  "Architecture migration source bytes changed before materialization"
          end
          aggregate = entry.fetch("record")
          disposition = aggregate.fetch("dispositions").values.flatten.find do |candidate|
            candidate.fetch("id") == thesis_id
          end
          raise StaleSource, "Architecture migration thesis is missing" unless disposition

          architecture_store.patrol_fix_admission_outbox.migration_snapshot(
            aggregate, disposition
          )
        rescue KeyError, ArgumentError => error
          raise StaleSource, "Architecture migration source is invalid: #{error.message}"
        end

        def assert_entry_binding!(entry, expected)
          unless entry.fetch("source_schema") == expected.fetch("source_schema") &&
                 entry.fetch("canonical_digest") == expected.fetch("canonical_digest")
            raise StaleSource, "migration source bytes changed before materialization"
          end
        end

        def augment_observations(snapshot, group)
          return snapshot unless group

          identities = Array(group.dig("canonical_decision", "observation_ids"))
          observations = @manifest.to_h.fetch("observation_dispositions").select do |entry|
            entry.fetch("group_id") == group.fetch("group_id") &&
              identities.include?(entry.fetch("identity"))
          end
          source_observations = group.fetch("members").flat_map do |member|
            @candidates.fetch(member).fetch("observations")
          end
          selected = source_observations.select do |entry|
            observations.any? do |disposition|
              disposition.values_at("kind", "identity") == entry.values_at("kind", "identity")
            end
          end
          publications = selected.filter_map do |entry|
            entry.dig("details", "publication") if
              entry.fetch("kind") == "pull_request" && entry.fetch("match") == "exact"
          end
          return snapshot if publications.empty?

          Hive::PatrolFix::SourceSnapshot.new(
            Hive::PatrolFix.deep_copy(snapshot.to_h).merge(
              "existing_pull_requests" => publications.uniq.sort_by do |payload|
                Hive::PatrolFix.canonical_json(payload)
              end
            )
          )
        end

        # A blocked member has no task/source backpointer by contract. This is
        # a durable controller disposition receipt bound to the U8 manifest;
        # final verification treats it separately from source acknowledgements.
        def blocked_acknowledgement(member, outcome)
          Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
            "source" => member, "route" => outcome.fetch("route"),
            "canonical_identity" => outcome["canonical_identity"]
          )).prepend("blocked:")
        end

        def outbox_for(kind)
          case kind
          when "ordinary_finding" then ordinary_store.patrol_fix_admission_outbox
          when "architecture_finding" then architecture_store.patrol_fix_admission_outbox
          else raise StaleSource, "migration source cannot be acknowledged"
          end
        end

        def verify_task!(binding)
          matches = Dir.glob(
            File.join(ordinary_store.hive_state_path, "stages", "*", binding.fetch("slug"))
          ).select { |path| File.directory?(path) }
          raise StaleSource, "canonical Patrol-fix task is missing or ambiguous" unless matches.one?

          manifest = Hive::PatrolFix::TaskManifest.new(task_folder: matches.first).read
          current = {
            "slug" => manifest.dig("task", "slug"),
            "generation" => manifest.dig("task", "generation"),
            "evidence_digest" => manifest.dig("evidence_revision", "digest")
          }
          raise StaleSource, "canonical Patrol-fix task binding changed" unless current == binding
        end

        def verify_source_acknowledgement!(member, task, receipt_id, group)
          snapshot = snapshot_for(member, group: group)
          candidate = candidate_for(member)
          outbox = outbox_for(candidate.fetch("source_kind"))
          record = outbox.fetch(outbox.migration_occurrence_id(snapshot))
          unless record && record.fetch("status") == "settled" &&
                 record.dig("acknowledgement", "receipt_id") == receipt_id &&
                 record.dig("acknowledgement", "task") == task
            raise StaleSource,
                  "migration source acknowledgement is missing or changed"
          end
        end

        def verify_blocking_dispositions!(group, progress)
          group.fetch("members").each do |member|
            outcome = {
              "route" => group.dig("canonical_decision", "route"),
              "canonical_identity" =>
                group.dig("canonical_decision", "canonical_identity")
            }
            expected = blocked_acknowledgement(member, outcome)
            unless progress.fetch("acknowledgements").fetch(member) == expected
              raise StaleSource, "blocked migration disposition receipt changed"
            end
          end
        end

        def source_ref(candidate)
          "#{candidate.fetch('source_kind')}:#{candidate.fetch('source_id')}"
        end

        def migration_admission_id(group, member)
          unless group && group.fetch("members").include?(member)
            raise StaleSource, "migration source acknowledgement lacks its semantic group"
          end
          "migration-#{Digest::SHA256.hexdigest(
            [ group.fetch("group_id"), member ].join("\0")
          )}"
        end
      end
    end
  end
end
