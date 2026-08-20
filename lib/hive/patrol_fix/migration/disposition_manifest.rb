require "digest"
require "json"
require "hive/patrol_fix"

module Hive
  module PatrolFix
    module Migration
      # Deterministic U8 preflight artifact. It has no timestamp or mutation
      # authority; identical authoritative inputs reproduce identical bytes.
      class DispositionManifest
        SCHEMA = "hive-patrol-fix-migration-disposition-manifest".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 64 * 1024 * 1024
        TOP_LEVEL_KEYS = %w[
          schema schema_version inventory semantic_groups dispositions
          observation_dispositions integrity
        ].freeze

        class IntegrityError < Hive::Error; end

        attr_reader :canonical_bytes

        class << self
          def build(inventory:, reconciliation:)
            candidates = PatrolFix.deep_copy(inventory.fetch("candidates"))
            root = inventory_root(candidates)
            unless inventory.fetch("count") == candidates.length &&
                   inventory.fetch("root_digest") == root
              invalid!("migration inventory count or root digest is inconsistent")
            end
            dispositions = PatrolFix.deep_copy(reconciliation.fetch("dispositions"))
            refs = candidates.map { |entry| source_ref(entry) }
            disposition_refs = dispositions.map { |entry| source_ref(entry) }
            unless disposition_refs.length == refs.length &&
                   disposition_refs.uniq.length == disposition_refs.length &&
                   disposition_refs.sort == refs.sort
              invalid!("every migration source must have exactly one disposition")
            end
            by_ref = candidates.to_h { |entry| [ source_ref(entry), entry ] }
            dispositions.each do |entry|
              source = by_ref.fetch(source_ref(entry))
              unless entry.fetch("source_schema") == source.fetch("source_schema") &&
                     entry.fetch("canonical_digest") == source.fetch("canonical_digest")
                invalid!("migration disposition source binding is inconsistent")
              end
            end
            groups = PatrolFix.deep_copy(reconciliation.fetch("groups"))
            verify_groups!(groups, by_ref, dispositions)
            observations = PatrolFix.deep_copy(
              reconciliation.fetch("observation_dispositions")
            )
            observation_keys = observations.map do |entry|
              [ entry.fetch("kind"), entry.fetch("identity") ]
            end
            invalid!("migration observation has multiple dispositions") unless
              observation_keys.uniq.length == observation_keys.length
            group_ids = groups.to_h { |group| [ group.fetch("group_id"), true ] }
            observations.each do |entry|
              invalid!("migration observation points to an unknown semantic group") unless
                group_ids[entry.fetch("group_id")]
            end
            opaque = PatrolFix.deep_copy(inventory.fetch("opaque_v3"))
            verify_opaque!(opaque)

            document = {
              "schema" => SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "inventory" => {
                "count" => candidates.length,
                "root_digest" => root,
                "candidates" => candidates,
                "opaque_v3" => opaque
              },
              "semantic_groups" => groups,
              "dispositions" => dispositions,
              "observation_dispositions" => observations,
              "integrity" => {
                "inventory_count" => candidates.length,
                "disposition_count" => dispositions.length,
                "reconstructed_root_digest" => root,
                "opaque_v3_count" => inventory.dig("opaque_v3", "count")
              }
            }
            new(document)
          rescue KeyError => error
            invalid!("migration manifest is missing #{error.key.inspect}")
          end

          def inventory_root(candidates)
            projection = Array(candidates).map do |entry|
              entry.slice("source_kind", "source_id", "source_schema", "canonical_digest")
            end.sort_by { |entry| [ entry.fetch("source_kind"), entry.fetch("source_id") ] }
            Digest::SHA256.hexdigest(PatrolFix.canonical_json(projection))
          end

          def source_ref(entry)
            "#{entry.fetch('source_kind')}:#{entry.fetch('source_id')}"
          end

          private

          def verify_groups!(groups, by_ref, dispositions)
            members = []
            disposition_groups = dispositions.to_h do |entry|
              [ source_ref(entry), entry.fetch("group_id") ]
            end
            dispositions_by_ref = dispositions.to_h do |entry|
              [ source_ref(entry), entry ]
            end
            group_ids = {}
            groups.each do |group|
              group_id = group.fetch("group_id")
              invalid!("migration semantic group is duplicated") if group_ids[group_id]
              group_ids[group_id] = true
              group_members = group.fetch("members")
              invalid!("migration semantic group has no members") if group_members.empty?
              invalid!("migration semantic group repeats a member") unless
                group_members.uniq.length == group_members.length
              canonical = group.fetch("canonical_source")
              invalid!("migration semantic group canonical source is not a member") unless
                group_members.include?(canonical)
              expected_set_digest = Digest::SHA256.hexdigest(
                PatrolFix.canonical_json(group_members.sort.map do |ref|
                  [ ref, by_ref.fetch(ref).fetch("canonical_digest") ]
                end)
              )
              invalid!("migration semantic group candidate digest is inconsistent") unless
                group.fetch("candidate_set_digest") == expected_set_digest
              group_members.each do |ref|
                invalid!("migration disposition points to the wrong semantic group") unless
                  disposition_groups.fetch(ref) == group_id
              end
              decision = group.fetch("canonical_decision")
              invalid!("migration semantic group has planned preflight mutations") unless
                decision.fetch("planned_mutations") == []
              group_members.each do |ref|
                disposition = dispositions_by_ref.fetch(ref)
                unless disposition &&
                       disposition.fetch("route") == decision.fetch("route") &&
                       disposition.fetch("canonical_identity") ==
                         decision.fetch("canonical_identity")
                  invalid!("migration disposition disagrees with its canonical decision")
                end
              end
              members.concat(group_members)
            end
            unless members.length == by_ref.length && members.uniq.length == members.length &&
                   members.sort == by_ref.keys.sort
              invalid!("migration semantic groups do not partition the inventory")
            end
            owned = groups.filter_map do |group|
              identity = group.dig("canonical_decision", "canonical_identity")
              [ identity, group.fetch("group_id") ] if identity
            end
            unless owned.map(&:first).uniq.length == owned.length
              invalid!("one canonical artifact is bound to multiple semantic groups")
            end
          rescue KeyError
            invalid!("migration semantic group binding is incomplete")
          end

          def verify_opaque!(opaque)
            unless opaque.is_a?(Hash) &&
                   opaque.keys.sort == %w[count entries root_digest]
              invalid!("opaque v3 inventory fields are invalid")
            end
            entries = opaque.fetch("entries")
            unless entries.is_a?(Array) && opaque.fetch("count") == entries.length
              invalid!("opaque v3 inventory count is inconsistent")
            end
            ids = entries.map { |entry| entry.fetch("source_id") }
            invalid!("opaque v3 inventory repeats a source") unless ids.uniq.length == ids.length
            expected = Digest::SHA256.hexdigest(PatrolFix.canonical_json(entries))
            invalid!("opaque v3 inventory root digest is inconsistent") unless
              opaque.fetch("root_digest") == expected
          rescue KeyError
            invalid!("opaque v3 inventory binding is incomplete")
          end

          def invalid!(message)
            raise IntegrityError, message.to_s[0, 512]
          end
        end

        def initialize(document)
          @document = PatrolFix.deep_freeze(PatrolFix.deep_copy(document))
          @canonical_bytes = PatrolFix.canonical_json(@document).freeze
          if @canonical_bytes.bytesize > MAX_BYTES
            raise IntegrityError, "migration manifest exceeds the size limit"
          end
        end

        def to_h = @document

        def verify!
          rebuilt = self.class.build(
            inventory: @document.fetch("inventory"),
            reconciliation: {
              "groups" => @document.fetch("semantic_groups"),
              "dispositions" => @document.fetch("dispositions"),
              "observation_dispositions" => @document.fetch("observation_dispositions")
            }
          )
          unless rebuilt.canonical_bytes == canonical_bytes &&
                 @document.keys.sort == TOP_LEVEL_KEYS.sort
            raise IntegrityError, "migration manifest bytes do not reconstruct"
          end
          true
        end
      end
    end
  end
end
