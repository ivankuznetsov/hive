require "digest"
require "hive/patrol_fix"

module Hive
  module Patrol
    # Source-owned ordinary Patrol adapter for the source-neutral migration
    # inventory. It translates authoritative finding records but never mutates
    # their lifecycle, outbox, claim, patch, or downstream effects.
    class MigrationInventory
      SUPPORT_KEYS = %w[fingerprints occurrences].freeze
      FINGERPRINT_DETAIL_KEYS = %w[
        base_branch base_oid base_sha branch head_oid head_sha intent_id
        occurrence_id patch_id pr_state pr_url receipt_id repository state
        worktree_path
      ].freeze
      MAX_SUPPORT_OBSERVATIONS = 16_384

      def initialize(state_store)
        @state_store = state_store
      end

      def migration_page(limit:, cursor: nil)
        support = support_index
        source = @state_store.patrol_fix_migration_page(
          limit: limit, cursor: cursor
        )
        {
          "entries" => source.fetch("entries").filter_map do |entry|
            candidate(entry, support)
          end,
          "next_cursor" => source.fetch("next_cursor"),
          "snapshot_token" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(
              "findings" => source.fetch("snapshot_token"),
              "support" => support.fetch("digest")
            )
          )
        }
      end

      def opaque_v3_entries = []

      private

      def candidate(entry, support)
        if entry.fetch("error")
          return blocked_candidate(entry)
        end
        record = entry.fetch("record")
        return nil unless record.fetch("lifecycle_state", "active") == "active"

        fingerprint = semantic_root(record)
        observations = observations_for(fingerprint, support)
        {
          "source_kind" => "ordinary_finding",
          "source_id" => entry.fetch("source_id"),
          "source_schema" => entry.fetch("source_schema"),
          "canonical_digest" => entry.fetch("canonical_digest"),
          "authority_state" => observations.any? { |item| item.fetch("kind") == "claim" } ?
            "claimed" : "accepted",
          "semantic_root" => fingerprint,
          "observations" => observations,
          "blocking_reason" => nil
        }
      rescue KeyError, TypeError, Hive::ConfigError
        blocked_candidate(entry)
      end

      def blocked_candidate(entry, reason: nil)
        {
          "source_kind" => "ordinary_finding",
          "source_id" => entry.fetch("source_id"),
          "source_schema" => entry.fetch("source_schema"),
          "canonical_digest" => entry.fetch("canonical_digest"),
          "authority_state" => "blocked",
          "semantic_root" => nil,
          "observations" => [],
          "blocking_reason" => reason ||
            "ordinary Patrol source record is corrupt or unsupported"
        }
      end

      def support_index
        @support_index ||= begin
          raw = if @state_store.respond_to?(:patrol_fix_migration_support_snapshot)
            @state_store.patrol_fix_migration_support_snapshot
          else
            {
              "fingerprints" => @state_store.patrol_fix_migration_fingerprints,
              "occurrences" =>
                @state_store.each_patrol_fix_migration_active_occurrence.to_a
            }
          end
          unless raw.is_a?(Hash) && raw.keys.sort == SUPPORT_KEYS
            raise Hive::ConfigError, "ordinary Patrol migration support is malformed"
          end
          build_support_index(raw)
        rescue Hive::ConfigError, KeyError, TypeError
          raise Hive::ConfigError,
                "ordinary Patrol claim or effect evidence is unavailable"
        end
      end

      def build_support_index(raw)
        fingerprints = raw.fetch("fingerprints")
        occurrences = raw.fetch("occurrences")
        unless fingerprints.is_a?(Hash) && occurrences.is_a?(Array)
          raise Hive::ConfigError, "ordinary Patrol migration support is malformed"
        end
        global = []
        by_fingerprint = Hash.new { |hash, key| hash[key] = [] }
        occurrences.each do |record|
          occurrence_observations(record, global, by_fingerprint)
        end
        count = global.length + by_fingerprint.values.sum(&:length)
        if count > MAX_SUPPORT_OBSERVATIONS
          raise Hive::ConfigError, "ordinary Patrol migration support is too large"
        end
        frozen_index = by_fingerprint.each_with_object({}) do |(key, value), result|
          result[key] = value
        end
        digest_payload = {
          "fingerprints" => fingerprints,
          "global" => global,
          "by_fingerprint" => frozen_index.sort.to_h
        }
        Hive::PatrolFix.deep_freeze(
          "global" => global,
          "by_fingerprint" => frozen_index,
          "fingerprints" => fingerprints,
          "digest" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(digest_payload)
          )
        )
      end

      def occurrence_observations(record, global, by_fingerprint)
        occurrence_id = record.fetch("occurrence_id").to_s
        if record.fetch("phase") == "reserved"
          global << observation(
            "claim", occurrence_id, "claimed", "wait", record,
            "occurrence_id" => occurrence_id,
            "phase" => "reserved"
          )
        end
        record.fetch("effects").values.each do |cell|
          semantic = cell.fetch("semantic")
          scope = semantic.fetch("scope")
          fingerprint = scope["fingerprint"].to_s
          next if fingerprint.empty?

          details = scope.slice(
            "base_branch", "base_sha", "branch", "head_sha", "patch_id",
            "repository", "worktree_path"
          ).merge(
            "intent_id" => semantic.fetch("intent_id"),
            "occurrence_id" => occurrence_id,
            "state" => cell.fetch("state")
          )
          values = by_fingerprint[fingerprint]
          add_effect_observations(values, semantic, cell, details)
        end
      end

      def add_effect_observations(values, semantic, cell, details)
        sink = semantic.fetch("sink")
        state = cell.fetch("state")
        source = { "semantic" => semantic, "cell" => cell }
        if details["patch_id"]
          values << observation(
            "validated_patch", details.fetch("patch_id"), state, "exact",
            source, details
          )
        end
        case sink
        when "branch"
          values << observation(
            "branch", semantic.fetch("target"), state, "exact", source,
            details
          )
        when "pull_request"
          values << observation(
            "publication_intent", semantic.fetch("intent_id"), state,
            "observe", source, details
          )
          pr_url = cell.dig("outcome", "pr_url").to_s
          unless pr_url.empty?
            values << observation(
              "pull_request", pr_url,
              cell.dig("outcome", "state").to_s.downcase,
              "legacy_link", source, details.merge("pr_url" => pr_url)
            )
          end
        when "review_handoff"
          task_path = cell.dig("outcome", "task_path").to_s
          unless task_path.empty?
            values << observation(
              "coding_task", task_path, state, "exact", source, details
            )
          end
        end
      end

      def observations_for(fingerprint, support)
        values = support.fetch("global") +
          Array(support.fetch("by_fingerprint")[fingerprint])
        ledger = support.fetch("fingerprints")[fingerprint]
        values += fingerprint_observations(fingerprint, ledger) if ledger
        deduplicate_observations(values)
      end

      def fingerprint_observations(fingerprint, entry)
        unless entry.is_a?(Hash)
          raise Hive::ConfigError, "ordinary Patrol fingerprint entry is malformed"
        end
        digest_source = { "fingerprint" => fingerprint, "entry" => entry }
        details = entry.slice(*FINGERPRINT_DETAIL_KEYS)
        binding = entry["publication_binding"]
        details.merge!(binding.slice(*FINGERPRINT_DETAIL_KEYS)) if binding.is_a?(Hash)
        values = []
        branch = details["branch"].to_s
        unless branch.empty?
          values << observation(
            "branch", branch, entry.fetch("state", "observed").to_s,
            "legacy_link", digest_source, details
          )
        end
        patch_id = details["patch_id"].to_s
        unless patch_id.empty?
          values << observation(
            "validated_patch", patch_id, "recorded", "exact",
            digest_source, details
          )
        end
        pr_url = details["pr_url"].to_s
        unless pr_url.empty?
          values << observation(
            "pull_request", pr_url,
            details.fetch("pr_state", entry.fetch("state", "unknown"))
                   .to_s.downcase,
            "legacy_link", digest_source, details
          )
        end
        values
      end

      def observation(kind, identity, state, match, digest_source, details)
        {
          "kind" => kind,
          "identity" => identity.to_s,
          "state" => state.to_s.empty? ? "unknown" : state.to_s,
          "match" => match,
          "canonical_digest" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(digest_source)
          ),
          "details" => Hive::PatrolFix.deep_copy(details)
        }
      end

      def deduplicate_observations(values)
        indexed = {}
        values.each do |entry|
          key = [ entry.fetch("kind"), entry.fetch("identity") ]
          existing = indexed[key]
          if existing && existing != entry
            indexed[key] = observation(
              entry.fetch("kind"), entry.fetch("identity"), "conflict",
              "uncertain", [ existing.fetch("canonical_digest"),
                              entry.fetch("canonical_digest") ].sort,
              "conflicting_digests" =>
                [ existing.fetch("canonical_digest"),
                  entry.fetch("canonical_digest") ].sort
            )
          else
            indexed[key] = entry
          end
        end
        indexed.values.sort_by do |entry|
          [ entry.fetch("kind"), entry.fetch("identity") ]
        end
      end

      def semantic_root(record)
        exact = record["fingerprint"] || record["validation_key"]
        return exact.to_s unless exact.to_s.empty?

        Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
          record.slice("feature_id", "category", "root_cause", "title")
        ))
      end
    end
  end
end
