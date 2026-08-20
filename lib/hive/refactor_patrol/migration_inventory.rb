require "digest"
require "find"
require "hive/patrol_fix"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Source-owned Architecture Patrol adapter. Runtime JobStore remains v4;
    # this adapter alone reports obsolete v3 files as opaque raw byte digests.
    class MigrationInventory
      MAX_OPAQUE_FILES = 16_384
      MAX_OPAQUE_FILE_BYTES = 64 * 1024 * 1024
      OBSERVATION_DETAIL_KEYS = %w[
        analysis_sha base_branch branch canonical_action_id commit_sha complete
        expires_at family_id generation head head_oid intent_id job_id kind
        merge_sha next_eligible_at occurrence_id outcome owner phase
        pr_url issue_url publication_id repository review_task_path state
        terminal thesis_id updated_at
      ].freeze

      def initialize(job_store, canonical_action_catalog: nil)
        @job_store = job_store
        @canonical_action_catalog = canonical_action_catalog
        @v3_root = File.join(File.dirname(@job_store.root), "v3")
      end

      def migration_page(limit:, cursor: nil)
        source = @job_store.patrol_fix_migration_page(
          limit: limit, cursor: cursor
        )
        catalog = catalog_snapshot
        entries = source.fetch("entries").flat_map do |entry|
          candidates(entry, catalog.fetch("observations"))
        end
        {
          "entries" => entries,
          "next_cursor" => source.fetch("next_cursor"),
          "snapshot_token" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(
              "jobs" => source.fetch("snapshot_token"),
              "catalog" => catalog.fetch("digest")
            )
          )
        }
      end

      def opaque_v3_entries
        return [] unless File.exist?(@v3_root)
        root_stat = File.lstat(@v3_root)
        raise Hive::ConfigError, "opaque Architecture Patrol v3 root is unsafe" unless root_stat.directory?

        entries = []
        Find.find(@v3_root) do |path|
          next if path == @v3_root

          stat = File.lstat(path)
          if stat.directory?
            next
          elsif !stat.file?
            raise Hive::ConfigError, "opaque Architecture Patrol v3 contains an unsupported entry"
          end
          entries << opaque_entry(path, stat)
          if entries.length > MAX_OPAQUE_FILES
            raise Hive::ConfigError, "opaque Architecture Patrol v3 inventory is too large"
          end
        end
        entries.sort_by { |entry| entry.fetch("source_id") }.freeze
      rescue Errno::ENOENT
        raise Hive::ConfigError, "opaque Architecture Patrol v3 changed during inventory"
      end

      private

      def candidates(entry, catalog)
        return [ blocked_job_candidate(entry) ] if entry.fetch("error")

        aggregate = entry.fetch("record")
        shared_observations = job_observations(aggregate)
        all_observations = merge_catalog_observations(
          shared_observations + action_observations(aggregate),
          catalog.select do |observation|
            observation_owner_job(observation) == aggregate.fetch("job_id")
          end
        )
        actionable = aggregate.fetch("dispositions").values.flatten.select do |disposition|
          disposition["admissible"] == true &&
            %w[fix discuss].include?(disposition["route"])
        end
        if actionable.empty?
          return [] if aggregate.fetch("complete") == true

          return [
            base_candidate(entry, aggregate.fetch("job_id"), nil, all_observations).merge(
              "source_kind" => "architecture_job",
              "authority_state" => live_claim?(all_observations) ? "claimed" : "blocked",
              "blocking_reason" => live_claim?(all_observations) ? nil :
                "Architecture Patrol job has no admitted finding yet"
            )
          ]
        end

        actionable.map do |disposition|
          identity = "#{aggregate.fetch('job_id')}:#{disposition.fetch('id')}"
          observations = merge_catalog_observations(
            shared_observations + action_observations(aggregate, disposition),
            catalog_observations_for(aggregate, disposition, catalog)
          )
          base_candidate(entry, identity, semantic_root(disposition), observations).merge(
            "source_kind" => "architecture_finding",
            "authority_state" => live_claim?(observations) ? "claimed" : "accepted",
            "blocking_reason" => nil
          )
        end
      rescue KeyError, TypeError
        [ blocked_job_candidate(entry) ]
      end

      def base_candidate(entry, identity, semantic_root, observations)
        {
          "source_kind" => "architecture_finding",
          "source_id" => identity,
          "source_schema" => entry.fetch("source_schema"),
          "canonical_digest" => candidate_digest(entry, identity),
          "authority_state" => "accepted",
          "semantic_root" => semantic_root,
          "observations" => observations,
          "blocking_reason" => nil
        }
      end

      def blocked_job_candidate(entry)
        {
          "source_kind" => "architecture_job",
          "source_id" => entry.fetch("source_id"),
          "source_schema" => entry.fetch("source_schema"),
          "canonical_digest" => entry.fetch("canonical_digest"),
          "authority_state" => "blocked",
          "semantic_root" => nil,
          "observations" => [],
          "blocking_reason" => "Architecture Patrol v4 job is corrupt or unsupported"
        }
      end

      def candidate_digest(entry, identity)
        Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
          "job_digest" => entry.fetch("canonical_digest"),
          "source_identity" => identity
        ))
      end

      def semantic_root(disposition)
        value = disposition["fingerprint"] || disposition["family_id"] ||
          disposition["id"]
        value.to_s
      end

      def job_observations(aggregate)
        values = [ observation(
          "architecture_job", aggregate.fetch("job_id"),
          aggregate.fetch("state"), "exact", aggregate
        ) ]
        Array(aggregate["attempts"]).each do |attempt|
          next unless %w[claimed running].include?(attempt["state"])

          values << observation(
            "claim",
            "#{aggregate.fetch('job_id')}:#{attempt['kind']}:#{attempt['generation']}",
            attempt.fetch("state"), "wait", attempt
          )
        end
        deduplicate_observations(values)
      end

      def action_observations(aggregate, disposition = nil)
        values = []
        selected_actions(aggregate, disposition).each do |action|
          action_id = action.fetch("canonical_action_id")
          values << observation(
            "canonical_action", action_id,
            action.fetch("terminal") ? action.fetch("outcome").to_s : "pending",
            "exact", action
          )
          Array(action["claims"]).each do |claim|
            next unless %w[claimed running].include?(claim["state"])

            values << observation(
              "claim", "#{action_id}:claim:#{claim['generation']}",
              claim.fetch("state"), "wait", claim
            )
          end
          receipts = action.fetch("receipts", {})
          values.concat(receipt_observations(action, receipts))
        end
        deduplicate_observations(values)
      end

      def selected_actions(aggregate, disposition)
        actions = Array(aggregate["actions"])
        return actions unless disposition

        actions.select do |action|
          action["thesis_id"] == disposition.fetch("id") ||
            (!action["thesis_fingerprint"].to_s.empty? &&
             action["thesis_fingerprint"] == semantic_root(disposition))
        end
      end

      def catalog_observations_for(aggregate, disposition, catalog)
        action_ids = selected_actions(aggregate, disposition).map do |action|
          action.fetch("canonical_action_id")
        end
        catalog.select do |observation|
          observation_owner_job(observation) == aggregate.fetch("job_id") &&
            action_ids.include?(observation_action_id(observation))
        end
      end

      def receipt_observations(action, receipts)
        return [] unless receipts.is_a?(Hash)

        values = []
        action_id = action.fetch("canonical_action_id")
        if receipts["pr_url"]
          state = action.fetch("outcome") == "merged" ? "merged" : "open"
          match = action.fetch("terminal") == true ? "legacy_link" : "uncertain"
          values << observation("pull_request", receipts.fetch("pr_url"), state, match, receipts)
        end
        if receipts["issue_url"]
          values << observation(
            "issue", receipts.fetch("issue_url"), action.fetch("outcome").to_s,
            "exact", receipts
          )
        end
        if receipts["review_task_path"]
          values << observation(
            "coding_task", receipts.fetch("review_task_path"), "legacy_review",
            "link_read_only", receipts
          )
        end
        receipts.each do |key, value|
          next unless key.to_s.match?(/\Apatch(?:_|\z)/) && value.is_a?(Hash)

          values << observation(
            "validated_patch", "#{action_id}:#{key}", "recorded", "exact", value
          )
          if value["branch"]
            values << observation(
              "branch", value.fetch("branch"), "observed", "exact", value
            )
          end
        end
        Array(receipts["publication_attempts"]).each_with_index do |attempt, index|
          values << observation(
            "publication_intent", "#{action_id}:publication:#{index}",
            attempt.fetch("phase", "unknown").to_s, "observe", attempt
          )
        end
        values
      end

      def observation(kind, identity, state, match, details)
        normalized = Hive::PatrolFix.deep_copy(details)
        summary = normalized.slice(*OBSERVATION_DETAIL_KEYS)
        summary["field_names"] = normalized.keys.map(&:to_s).sort.first(256)
        {
          "kind" => kind,
          "identity" => identity.to_s,
          "state" => state.to_s.empty? ? "unknown" : state.to_s,
          "match" => match,
          "canonical_digest" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(normalized)
          ),
          "details" => summary
        }
      end

      def deduplicate_observations(values)
        indexed = {}
        values.each do |entry|
          key = [ entry.fetch("kind"), entry.fetch("identity") ]
          if indexed.key?(key) && indexed.fetch(key) != entry
            raise Hive::ConfigError,
                  "Architecture Patrol migration observation identity conflicts"
          end
          indexed[key] = entry
        end
        indexed.values.sort_by { |entry| [ entry.fetch("kind"), entry.fetch("identity") ] }
      end

      def merge_catalog_observations(local, catalog)
        catalog_keys = catalog.to_h do |entry|
          [ [ entry.fetch("kind"), entry.fetch("identity") ], true ]
        end
        deduplicate_observations(
          local.reject do |entry|
            catalog_keys[[ entry.fetch("kind"), entry.fetch("identity") ]]
          end + catalog
        )
      end

      def live_claim?(observations)
        observations.any? do |entry|
          entry.fetch("kind") == "claim" && %w[claimed running].include?(entry.fetch("state"))
        end
      end

      def catalog_observations
        return [] unless @canonical_action_catalog

        @canonical_action_catalog.patrol_fix_migration_observations
      end

      def catalog_snapshot
        @catalog_snapshot ||= begin
          observations = catalog_observations
          {
            "observations" => observations,
            "digest" => Digest::SHA256.hexdigest(
              Hive::PatrolFix.canonical_json(observations)
            )
          }.freeze
        end
      end

      def observation_owner_job(observation)
        observation.dig("details", "owner", "job_id")
      end

      def observation_action_id(observation)
        observation.dig("details", "canonical_action_id")
      end

      def opaque_entry(path, stat)
        if stat.size > MAX_OPAQUE_FILE_BYTES
          raise Hive::ConfigError, "opaque Architecture Patrol v3 file is too large"
        end
        bytes = read_opaque(path)
        repeated = read_opaque(path)
        unless bytes == repeated && bytes.bytesize == stat.size
          raise Hive::ConfigError, "opaque Architecture Patrol v3 changed during inventory"
        end
        {
          "source_id" => path.delete_prefix("#{@v3_root}/"),
          "canonical_digest" => Digest::SHA256.hexdigest(bytes),
          "byte_size" => bytes.bytesize
        }
      end

      def read_opaque(path)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          bytes = file.read(MAX_OPAQUE_FILE_BYTES + 1).to_s
          raise Hive::ConfigError, "opaque Architecture Patrol v3 file is too large" if
            bytes.bytesize > MAX_OPAQUE_FILE_BYTES
          bytes
        end
      rescue Errno::ELOOP
        raise Hive::ConfigError, "opaque Architecture Patrol v3 contains a link"
      end
    end
  end
end
