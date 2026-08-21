require "digest"
require "json"
require "time"
require "hive/managed_directory"
require "hive/patrol_fix"
require "hive/patrol_fix/cutover_gate"
require "hive/patrol_fix/migration/disposition_manifest"

module Hive
  module PatrolFix
    module Migration
      # Durable coordinator state for the one Patrol-fix authority cutover.
      # The source epochs are observations of the existing Patrol migration
      # authority; this store deliberately does not mint another epoch.
      class CutoverState
        SCHEMA = "hive-patrol-fix-migration-cutover-state".freeze
        SCHEMA_VERSION = 1
        STATUSES = %w[preflight fenced applying committed].freeze
        SOURCES = %w[architecture_patrol ordinary_patrol].freeze
        GROUP_STATUSES = %w[intent effect_armed task_bound acknowledging complete].freeze
        MAX_STATE_BYTES = 64 * 1024 * 1024
        MAX_MANIFEST_BYTES = DispositionManifest::MAX_BYTES
        DIGEST = /\A[0-9a-f]{64}\z/

        class Error < Hive::Error; end
        class Conflict < Error; end
        class CorruptState < Error; end
        class ForwardOnly < Error; end

        attr_reader :root

        def initialize(root:)
          @root = File.expand_path(root)
          @directory = Hive::ManagedDirectory.new(
            root: @root, label: "Patrol-fix migration cutover"
          )
        end

        def read
          bytes = @directory.read("state.json", max_bytes: MAX_STATE_BYTES, missing: true)
          bytes && parse_state(bytes)
        rescue Hive::ManagedDirectory::UnsafeError => error
          corrupt!(error.message)
        end

        def manifest
          bytes = @directory.read(
            "manifest.json", max_bytes: MAX_MANIFEST_BYTES, missing: true
          )
          corrupt!("Patrol-fix migration manifest is missing") unless bytes
          document = JSON.parse(bytes)
          value = DispositionManifest.new(document)
          value.verify!
          corrupt!("Patrol-fix migration manifest bytes changed") unless
            value.canonical_bytes.b == bytes.b
          state = read
          corrupt!("Patrol-fix migration state is missing") unless state
          corrupt!("Patrol-fix migration manifest digest changed") unless
            state.fetch("manifest_digest") == Digest::SHA256.hexdigest(bytes)
          value
        rescue JSON::ParserError, EncodingError,
               DispositionManifest::IntegrityError => error
          corrupt!(error.message)
        rescue Hive::ManagedDirectory::UnsafeError => error
          corrupt!(error.message)
        end

        def preflight!(manifest:, source_epochs:, source_ownership: nil,
                       now: Time.now.utc)
          manifest.verify!
          bytes = manifest.canonical_bytes
          corrupt!("Patrol-fix migration manifest exceeds the size limit") if
            bytes.bytesize > MAX_MANIFEST_BYTES
          epochs = normalize_epochs(source_epochs)
          ownership = normalize_ownership(
            source_ownership || SOURCES.to_h do |source|
              [ source, { "owner" => "legacy", "admission" => true } ]
            end
          )
          digest = Digest::SHA256.hexdigest(bytes)
          mutate(create: true) do |current|
            if current
              if current.fetch("status") == "preflight" &&
                 current.fetch("groups").empty? &&
                 current.fetch("new_authority_effect") == false &&
                 current.fetch("acknowledgement_count").zero?
                @directory.atomic_write("manifest.json", bytes, mode: 0o600)
                next touch(
                  current.merge(
                    "manifest_digest" => digest, "source_epochs" => epochs,
                    "source_ownership" => ownership,
                    "groups" => {}, "new_authority_effect" => false,
                    "acknowledgement_count" => 0, "final_verification" => nil
                  ), now
                )
              end
              conflict!("Patrol-fix migration manifest conflicts with durable preflight") unless
                current.fetch("manifest_digest") == digest
              next current
            end
            @directory.atomic_write("manifest.json", bytes, mode: 0o600)
            {
              "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
              "status" => "preflight", "manifest_digest" => digest,
              "source_epochs" => epochs, "source_ownership" => ownership,
              "fenced_source_epochs" => nil,
              "groups" => {}, "new_authority_effect" => false,
              "acknowledgement_count" => 0, "final_verification" => nil,
              "created_at" => timestamp(now), "updated_at" => timestamp(now)
            }
          end
        end

        def fence!(expected_source_epochs:, fenced_source_epochs:, now: Time.now.utc)
          expected = normalize_epochs(expected_source_epochs)
          fenced = normalize_epochs(fenced_source_epochs)
          mutate do |state|
            if %w[fenced applying committed].include?(state.fetch("status"))
              conflict!("Patrol-fix migration fenced epoch changed") unless
                state.fetch("source_epochs") == expected &&
                state.fetch("fenced_source_epochs") == fenced
              next state
            end
            conflict!("Patrol-fix migration is not ready to fence") unless
              state.fetch("status") == "preflight" &&
              state.fetch("source_epochs") == expected
            unless SOURCES.all? { |source| fenced.fetch(source) > expected.fetch(source) }
              conflict!("Patrol-fix migration fence did not advance existing source epochs")
            end
            touch(
              state.merge(
                "status" => "fenced", "fenced_source_epochs" => fenced
              ), now
            )
          end
        end

        def start_applying!(now: Time.now.utc)
          mutate do |state|
            next state if %w[applying committed].include?(state.fetch("status"))
            conflict!("Patrol-fix migration is not fenced") unless
              state.fetch("status") == "fenced"
            touch(state.merge("status" => "applying"), now)
          end
        end

        def begin_group!(intent, now: Time.now.utc)
          normalized = normalize_intent(intent)
          mutate do |state|
            conflict!("Patrol-fix migration is not applying") unless
              state.fetch("status") == "applying"
            groups = PatrolFix.deep_copy(state.fetch("groups"))
            existing = groups[normalized.fetch("group_id")]
            if existing
              conflict!("Patrol-fix migration group intent conflicts") unless
                existing.fetch("intent") == normalized
              next state
            end
            groups[normalized.fetch("group_id")] = {
              "status" => "intent", "intent" => normalized,
              "task" => nil, "acknowledgements" => {}
            }
            touch(state.merge("groups" => groups), now)
          end
          normalized
        end

        # Persist this immediately before calling a task materializer. A crash
        # after the call can no longer prove that no task bytes were written,
        # so recovery is intentionally forward-only from this point.
        def arm_group_effect!(group_id, now: Time.now.utc)
          mutate_group(group_id, now: now) do |state, groups, group|
            unless %w[intent effect_armed task_bound acknowledging complete]
                     .include?(group.fetch("status"))
              conflict!("Patrol-fix migration group cannot arm its effect")
            end
            unless %w[task_bound acknowledging complete].include?(group.fetch("status"))
              group["status"] = "effect_armed"
            end
            state["new_authority_effect"] = true
            groups[group_id.to_s] = group
          end
        end

        def record_group_task!(group_id, task:, now: Time.now.utc)
          binding = normalize_task(task)
          mutate_group(group_id, now: now) do |_state, groups, group|
            conflict!("Patrol-fix migration group effect is not armed") unless
              %w[effect_armed task_bound acknowledging complete].include?(group.fetch("status"))
            if group["task"]
              conflict!("Patrol-fix migration group task conflicts") unless
                group.fetch("task") == binding
            else
              group["task"] = binding
            end
            group["status"] = "task_bound" unless
              %w[acknowledging complete].include?(group.fetch("status"))
            groups[group_id.to_s] = group
          end
          binding
        end

        def group_task(group_id)
          read&.dig("groups", group_id.to_s, "task")
        end

        def acknowledge_member!(group_id, member:, receipt_id:, now: Time.now.utc)
          ref = bounded_text(member, "source member", max: 4_096)
          receipt = bounded_text(receipt_id, "source acknowledgement", max: 512)
          mutate_group(group_id, now: now) do |state, groups, group|
            blocked = group.dig("intent", "route").start_with?("blocked_")
            conflict!("Patrol-fix migration source acknowledgement has no task") unless
              blocked || group["task"]
            conflict!("Patrol-fix migration source is not in its semantic group") unless
              group.dig("intent", "members").include?(ref)
            acknowledgements = group.fetch("acknowledgements")
            if acknowledgements.key?(ref)
              conflict!("Patrol-fix migration source acknowledgement conflicts") unless
                acknowledgements.fetch(ref) == receipt
            else
              acknowledgements[ref] = receipt
              state["acknowledgement_count"] += 1
            end
            group["status"] = "acknowledging"
            groups[group_id.to_s] = group
          end
        end

        def complete_group!(group_id, now: Time.now.utc)
          mutate_group(group_id, now: now) do |_state, groups, group|
            members = group.dig("intent", "members")
            task_required = !group.dig("intent", "route").start_with?("blocked_")
            if task_required
              conflict!("Patrol-fix migration group has no canonical task") unless group["task"]
            end
            conflict!("Patrol-fix migration group acknowledgements are incomplete") unless
              group.fetch("acknowledgements").keys.sort == members.sort
            group["status"] = "complete"
            groups[group_id.to_s] = group
          end
        end

        def commit!(verification:, now: Time.now.utc)
          proof = normalize_verification(verification)
          mutate do |state|
            next state if state.fetch("status") == "committed" &&
                          state.fetch("final_verification") == proof
            conflict!("Patrol-fix migration is not applying") unless
              state.fetch("status") == "applying"
            expected_groups = manifest.to_h.fetch("semantic_groups").map do |group|
              group.fetch("group_id")
            end.sort
            completed = state.fetch("groups").select do |_id, group|
              group.fetch("status") == "complete"
            end.keys.sort
            conflict!("Patrol-fix migration groups are incomplete") unless
              completed == expected_groups
            integrity = manifest.to_h.fetch("integrity")
            valid = proof.fetch("inventory_count") == integrity.fetch("inventory_count") &&
              proof.fetch("inventory_root_digest") == integrity.fetch("reconstructed_root_digest") &&
              proof.fetch("disposition_count") == integrity.fetch("disposition_count") &&
              proof.fetch("completed_group_count") == expected_groups.length
            conflict!("Patrol-fix migration final verification is inconsistent") unless valid
            touch(
              state.merge(
                "status" => "committed", "final_verification" => proof
              ), now
            )
          end
        end

        def rollback_allowed?
          state = read
          state && %w[preflight fenced].include?(state.fetch("status")) &&
            state.fetch("new_authority_effect") == false &&
            state.fetch("acknowledgement_count").zero?
        end

        def rollback!(source_epochs:, now: Time.now.utc)
          restored = normalize_epochs(source_epochs)
          mutate do |state|
            raise ForwardOnly, "Patrol-fix migration has crossed its forward-only boundary" unless
              %w[preflight fenced].include?(state.fetch("status")) &&
              state.fetch("new_authority_effect") == false &&
              state.fetch("acknowledgement_count").zero?
            fenced = state["fenced_source_epochs"]
            if fenced && !SOURCES.all? { |source| restored.fetch(source) > fenced.fetch(source) }
              conflict!("Patrol-fix migration rollback did not advance existing source epochs")
            end
            touch(
              state.merge(
                "status" => "preflight", "source_epochs" => restored,
                "fenced_source_epochs" => nil, "groups" => {},
                "final_verification" => nil
              ), now
            )
          end
        end

        def fenced_source_epochs
          read&.fetch("fenced_source_epochs")
        end

        def gate_for(source)
          name = source.to_s
          conflict!("Patrol-fix migration source is invalid") unless SOURCES.include?(name)
          state = read
          enabled = state && %w[fenced applying committed].include?(state.fetch("status"))
          epoch = enabled && state.fetch("fenced_source_epochs").fetch(name).to_s
          CutoverGate.new(enabled: enabled == true, epoch: epoch)
        end

        private

        def mutate(create: false)
          @directory.with_lock("cutover.lock") do
            original = @directory.read(
              "state.json", max_bytes: MAX_STATE_BYTES, missing: true
            )
            state = original && parse_state(original)
            conflict!("Patrol-fix migration preflight is missing") unless state || create
            replacement = yield(state && PatrolFix.deep_copy(state))
            validate_state!(replacement)
            bytes = PatrolFix.canonical_json(replacement)
            corrupt!("Patrol-fix migration state exceeds the size limit") if
              bytes.bytesize > MAX_STATE_BYTES
            next PatrolFix.deep_freeze(replacement) if bytes == original
            @directory.atomic_write(
              "state.json", bytes, mode: 0o600,
              expected_digest: original && Digest::SHA256.hexdigest(original),
              max_existing_bytes: MAX_STATE_BYTES
            )
            PatrolFix.deep_freeze(replacement)
          end
        rescue Hive::ManagedDirectory::UnsafeError => error
          corrupt!(error.message)
        end

        def mutate_group(group_id, now:)
          id = bounded_text(group_id, "semantic group", max: 128)
          mutate do |state|
            conflict!("Patrol-fix migration is not applying") unless
              state.fetch("status") == "applying"
            groups = PatrolFix.deep_copy(state.fetch("groups"))
            group = groups[id]
            conflict!("Patrol-fix migration group intent is missing") unless group
            yield(state, groups, group)
            touch(state.merge("groups" => groups), now)
          end
        end

        def parse_state(bytes)
          value = JSON.parse(bytes)
          corrupt!("Patrol-fix migration state is not canonical") unless
            PatrolFix.canonical_json(value).b == bytes.b
          validate_state!(value)
          PatrolFix.deep_freeze(value)
        rescue JSON::ParserError, EncodingError
          corrupt!("Patrol-fix migration state is malformed")
        end

        def validate_state!(state)
          keys = %w[
            acknowledgement_count created_at fenced_source_epochs final_verification
            groups manifest_digest new_authority_effect schema schema_version
            source_epochs source_ownership status updated_at
          ]
          valid = state.is_a?(Hash) && state.keys.sort == keys.sort &&
            state["schema"] == SCHEMA && state["schema_version"] == SCHEMA_VERSION &&
            STATUSES.include?(state["status"]) && state["manifest_digest"].match?(DIGEST) &&
            normalize_epochs(state["source_epochs"]) == state["source_epochs"] &&
            normalize_ownership(state["source_ownership"]) == state["source_ownership"] &&
            state["groups"].is_a?(Hash) &&
            [ true, false ].include?(state["new_authority_effect"]) &&
            state["acknowledgement_count"].is_a?(Integer) &&
            state["acknowledgement_count"] >= 0
          corrupt!("Patrol-fix migration state fields are invalid") unless valid
          if state["status"] == "preflight"
            corrupt!("Patrol-fix preflight unexpectedly has fenced epochs") if
              state["fenced_source_epochs"]
          else
            corrupt!("Patrol-fix fenced epochs are invalid") unless
              normalize_epochs(state["fenced_source_epochs"]) == state["fenced_source_epochs"]
          end
          state.fetch("groups").each do |id, group|
            validate_group!(id, group)
          end
          acknowledgement_count = state.fetch("groups").sum do |_id, group|
            group.fetch("acknowledgements").length
          end
          corrupt!("Patrol-fix migration acknowledgement count is invalid") unless
            acknowledgement_count == state.fetch("acknowledgement_count")
          normalize_verification(state["final_verification"]) if state["final_verification"]
          timestamp_value!(state.fetch("created_at"))
          timestamp_value!(state.fetch("updated_at"))
          state
        rescue NoMethodError, KeyError, TypeError, ArgumentError
          corrupt!("Patrol-fix migration state is malformed")
        end

        def validate_group!(id, group)
          bounded_text(id, "semantic group", max: 128)
          valid = group.is_a?(Hash) &&
            group.keys.sort == %w[acknowledgements intent status task] &&
            GROUP_STATUSES.include?(group["status"]) &&
            normalize_intent(group["intent"]) == group["intent"] &&
            group["intent"].fetch("group_id") == id &&
            group["acknowledgements"].is_a?(Hash)
          corrupt!("Patrol-fix migration group checkpoint is invalid") unless valid
          normalize_task(group["task"]) if group["task"]
          group.fetch("acknowledgements").each do |member, receipt|
            bounded_text(member, "source member", max: 4_096)
            bounded_text(receipt, "source acknowledgement", max: 512)
            corrupt!("Patrol-fix migration acknowledgement member is invalid") unless
              group.dig("intent", "members").include?(member)
          end
        end

        def normalize_intent(value)
          keys = %w[candidate_set_digest canonical_identity group_id members route]
          conflict!("Patrol-fix migration group intent fields are invalid") unless
            value.is_a?(Hash) && value.keys.sort == keys &&
            value["candidate_set_digest"].is_a?(String) &&
            value["candidate_set_digest"].match?(DIGEST) &&
            value["members"].is_a?(Array) && !value["members"].empty? &&
            value["members"].uniq.length == value["members"].length
          canonical = value["canonical_identity"]
          bounded_text(canonical, "canonical identity", max: 4_096) if canonical
          {
            "group_id" => bounded_text(value.fetch("group_id"), "semantic group", max: 128),
            "candidate_set_digest" => value.fetch("candidate_set_digest"),
            "route" => bounded_text(value.fetch("route"), "migration route", max: 128),
            "canonical_identity" => canonical,
            "members" => value.fetch("members").map do |member|
              bounded_text(member, "source member", max: 4_096)
            end
          }
        rescue KeyError
          conflict!("Patrol-fix migration group intent fields are invalid")
        end

        def normalize_epochs(value)
          conflict!("Patrol-fix migration source epochs are invalid") unless
            value.is_a?(Hash) && value.keys.sort == SOURCES &&
            value.values.all? { |epoch| epoch.is_a?(Integer) && epoch.positive? }
          SOURCES.to_h { |source| [ source, value.fetch(source) ] }
        rescue KeyError
          conflict!("Patrol-fix migration source epochs are invalid")
        end

        def normalize_ownership(value)
          conflict!("Patrol-fix migration source ownership is invalid") unless
            value.is_a?(Hash) && value.keys.sort == SOURCES
          SOURCES.to_h do |source|
            mode = value.fetch(source)
            valid = mode.is_a?(Hash) && mode.keys.sort == %w[admission owner] &&
              %w[legacy module].include?(mode["owner"]) &&
              [ true, false ].include?(mode["admission"])
            conflict!("Patrol-fix migration source ownership is invalid") unless valid
            [ source, mode.slice("owner", "admission") ]
          end
        rescue KeyError
          conflict!("Patrol-fix migration source ownership is invalid")
        end

        def normalize_task(value)
          keys = %w[evidence_digest generation slug]
          conflict!("Patrol-fix migration task binding is invalid") unless
            value.is_a?(Hash) && value.keys.sort == keys &&
            value["slug"].is_a?(String) && value["slug"].match?(/\A[a-z][a-z0-9-]{1,63}\z/) &&
            value["generation"].is_a?(Integer) && value["generation"].positive? &&
            value["evidence_digest"].is_a?(String) && value["evidence_digest"].match?(DIGEST)
          value.slice(*keys)
        end

        def normalize_verification(value)
          keys = %w[
            authority_digest completed_group_count disposition_count
            inventory_count inventory_root_digest
          ]
          conflict!("Patrol-fix migration final verification is invalid") unless
            value.is_a?(Hash) && value.keys.sort == keys &&
            %w[completed_group_count disposition_count inventory_count].all? do |key|
              value[key].is_a?(Integer) && value[key] >= 0
            end && value["inventory_root_digest"].is_a?(String) &&
            value["inventory_root_digest"].match?(DIGEST) &&
            value["authority_digest"].is_a?(String) && value["authority_digest"].match?(DIGEST)
          value.slice(*keys)
        end

        def touch(state, now)
          state["updated_at"] = timestamp(now)
          state
        end

        def bounded_text(value, label, max:)
          conflict!("#{label} is invalid") unless
            value.is_a?(String) && !value.empty? && value.bytesize <= max &&
            value.valid_encoding? && !value.match?(/[\u0000-\u001f\u007f]/)
          value
        end

        def timestamp(value) = value.utc.iso8601(6)

        def timestamp_value!(value)
          parsed = Time.iso8601(value.to_s)
          corrupt!("Patrol-fix migration timestamp is invalid") unless
            parsed.utc? && value.end_with?("Z")
        end

        def conflict!(message)
          raise Conflict, message.to_s[0, 512]
        end

        def corrupt!(message)
          raise CorruptState, message.to_s[0, 512]
        end
      end
    end
  end
end
