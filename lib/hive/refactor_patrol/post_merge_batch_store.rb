require "digest"
require "json"
require "time"
require "hive"
require "hive/managed_directory"
require "hive/refactor_patrol/pr_manifest"

module Hive
  module RefactorPatrol
    # Immutable claim authority for the accepted ClassificationStore queue.
    # Members are deterministic <=512-path occurrence chunks; no preliminary
    # JobStore rows exist. Only the synthetic batch owner reaches discovery.
    class PostMergeBatchStore
      SCHEMA = "hive-refactor-patrol-post-merge-batch".freeze
      SCHEMA_VERSION = 1
      LOCK_FILE = "batches.lock".freeze
      MAX_RECORD_BYTES = 8 * 1024 * 1024
      MAX_RECORDS = 20_000
      MAX_MEMBERS = 8
      MAX_CANDIDATES = 64
      MAX_PATHS = 512
      WINDOW_SEC = 600
      OID = /\A[0-9a-f]{40,64}\z/.freeze
      DIGEST = /\A[0-9a-f]{64}\z/.freeze
      RECORD_KEYS = %w[
        schema schema_version batch_id owner_job_id analysis_sha status members
        manifest_checksum created_at materialized_at
      ].freeze
      MEMBER_KEYS = %w[
        occurrence_id chunk_index chunk_count repository registration number
        merge_sha merged_at path_mappings
      ].freeze
      PATH_MAPPING_KEYS = %w[path slice_ids].freeze

      class Invalid < Hive::ConfigError; end
      class Conflict < Hive::Error; end

      def initialize(root:)
        @directory = Hive::ManagedDirectory.new(
          root: root, label: "post-merge Architecture Patrol batches"
        )
      end

      def claim!(primary_occurrence_id:, classifications:, analysis_sha:,
                 mappings:, now: Time.now.utc)
        instant = normalize_time(now)
        sha = analysis_sha.to_s
        raise Invalid, "post-merge batch analysis commit is invalid" unless OID.match?(sha)
        records = normalize_classifications(classifications)
        primary = records.find do |record|
          record.fetch("occurrence_id") == primary_occurrence_id.to_s
        end
        raise Invalid, "post-merge batch primary occurrence is absent" unless primary
        mapped = normalize_mappings(records, mappings)

        @directory.prepare!
        @directory.with_lock(LOCK_FILE) do
          batches = authoritative_records
          claimed = claimed_chunks(batches)
          primary_unit = first_unclaimed_unit(primary, mapped, claimed)
          raise Conflict, "post-merge occurrence is already fully claimed" unless primary_unit

          members = select_members(primary, primary_unit, records, mapped, claimed)
          record = build_record(members, sha, instant)
          raise Invalid, "post-merge batch inventory exceeds #{MAX_RECORDS}" if batches.size >= MAX_RECORDS

          @directory.atomic_write(
            record_relative(record.fetch("batch_id")), canonical_json(record), mode: 0o600
          )
          deep_copy(record)
        end
      end

      def pending(limit: 100)
        bound = Integer(limit)
        raise ArgumentError, "post-merge pending batch limit must be between 1 and 500" unless
          (1..500).cover?(bound)
        records = []
        each_record do |record|
          next unless %w[claimed materialized].include?(record.fetch("status"))

          records << record
          break if records.size >= bound
        end
        records
      end

      def batches_for_occurrence(occurrence_id)
        id = occurrence_id.to_s
        each_record.select do |record|
          record.fetch("members").any? { |member| member.fetch("occurrence_id") == id }
        end
      end

      def unclaimed?(classification)
        unclaimed_occurrence_ids([ classification ]).include?(classification.fetch("occurrence_id"))
      end

      # Consolidates membership inspection to one bounded BatchStore scan per
      # scheduler tick; no secondary index or cursor duplicates this authority.
      def unclaimed_occurrence_ids(classifications)
        return [] if Array(classifications).empty?

        records = normalize_classifications(classifications)
        claimed = claimed_chunks(authoritative_records)
        records.filter_map do |record|
          mappings = { record.fetch("occurrence_id") => snapshot_path_mappings(record) }
          record.fetch("occurrence_id") if first_unclaimed_unit(record, mappings, claimed)
        end.freeze
      end

      # Returns all owner bindings only after every deterministic source chunk
      # is claimed and each owning batch has crossed manifest->JobStore->event.
      def materialization_binding(classification)
        record = normalize_classifications([ classification ], require_unclaimed: false).first
        occurrence_id = record.fetch("occurrence_id")
        batches = batches_for_occurrence(occurrence_id)
        return nil if batches.empty? || batches.any? { |batch| batch.fetch("status") == "claimed" }

        expected = record.dig("snapshot", "changed_paths")
        observed = batches.flat_map do |batch|
          batch.fetch("members").select { |member| member.fetch("occurrence_id") == occurrence_id }
               .flat_map { |member| member.fetch("path_mappings").map { |mapping| mapping.fetch("path") } }
        end
        return nil unless observed.sort == expected.sort && observed.uniq.size == observed.size

        ordered = batches.sort_by { |batch| [ batch.fetch("created_at"), batch.fetch("batch_id") ] }
        {
          "job_ids" => ordered.map { |batch| batch.fetch("owner_job_id") },
          "manifest_checksums" => ordered.map { |batch| batch.fetch("manifest_checksum") }
        }
      end

      def fetch(batch_id)
        id = batch_id.to_s
        raise Invalid, "post-merge batch id is invalid" unless DIGEST.match?(id)
        bytes = @directory.read(record_relative(id), max_bytes: MAX_RECORD_BYTES, missing: true)
        bytes && parse_record(bytes, expected_batch_id: id)
      end

      def mark_materialized!(batch_id, job_id:, manifest_checksum:, now: Time.now.utc)
        instant = normalize_time(now)
        @directory.with_lock(LOCK_FILE) do
          record = fetch(batch_id)
          raise Invalid, "post-merge batch is missing" unless record
          unless record.fetch("owner_job_id") == job_id.to_s && DIGEST.match?(manifest_checksum.to_s)
            raise Invalid, "post-merge batch materialization identity is invalid"
          end
          if %w[materialized finalized].include?(record.fetch("status"))
            unless record.fetch("manifest_checksum") == manifest_checksum.to_s
              raise Conflict, "post-merge batch materialization changed"
            end
            return deep_copy(record)
          end
          record.merge!(
            "status" => "materialized", "manifest_checksum" => manifest_checksum.to_s,
            "materialized_at" => instant.iso8601(6)
          )
          persist(record)
          deep_copy(record)
        end
      end


      def finalize!(batch_id, job_id:, manifest_checksum:)
        @directory.with_lock(LOCK_FILE) do
          record = fetch(batch_id)
          raise Invalid, "post-merge batch is missing" unless record
          unless record.fetch("status") == "materialized" &&
                 record.fetch("owner_job_id") == job_id.to_s &&
                 record.fetch("manifest_checksum") == manifest_checksum.to_s
            if record.fetch("status") == "finalized" &&
               record.fetch("owner_job_id") == job_id.to_s &&
               record.fetch("manifest_checksum") == manifest_checksum.to_s
              return deep_copy(record)
            end
            raise Conflict, "post-merge batch finalization changed"
          end
          record["status"] = "finalized"
          persist(record)
          deep_copy(record)
        end
      end

      def each_record
        return enum_for(__method__) unless block_given?
        return unless File.directory?(@directory.root)
        names = @directory.each_child("records", missing: true).to_a
          .select { |name| /\A[0-9a-f]{64}\.json\z/.match?(name) }.sort
        raise Invalid, "post-merge batch inventory exceeds #{MAX_RECORDS}" if names.size > MAX_RECORDS
        names.each do |name|
          id = name.delete_suffix(".json")
          yield parse_record(
            @directory.read("records/#{name}", max_bytes: MAX_RECORD_BYTES),
            expected_batch_id: id
          )
        end
      end

      private

      def normalize_classifications(classifications, require_unclaimed: true)
        records = Array(classifications)
        unless records.size.between?(1, MAX_CANDIDATES) &&
               records.map { |record| record.is_a?(Hash) && record["occurrence_id"] }.uniq.size == records.size
          raise Invalid, "post-merge classifications are invalid"
        end
        records.each do |record|
          snapshot = record.fetch("snapshot")
          unless record.fetch("status") == "feature" && record.fetch("decision") == "feature" &&
                 (!require_unclaimed || record["materialization"].nil?) &&
                 DIGEST.match?(record["occurrence_id"].to_s) &&
                 snapshot.fetch("changed_paths").size.between?(1, 10_000)
            raise Invalid, "post-merge classification is not accepted unclaimed work"
          end
        end
        records.sort_by do |record|
          [ Time.iso8601(record.dig("snapshot", "merged_at")), record.fetch("occurrence_id") ]
        end
      rescue KeyError, ArgumentError => error
        raise Invalid, "post-merge classifications are invalid (#{error.message})"
      end

      def normalize_mappings(records, mappings)
        value = mappings.is_a?(Hash) ? mappings : {}
        records.to_h do |record|
          id = record.fetch("occurrence_id")
          paths = record.dig("snapshot", "changed_paths")
          mapped = Array(value[id])
          unless mapped.map { |entry| entry.is_a?(Hash) && entry["path"] } == paths &&
                 mapped.all? { |entry| valid_path_mapping?(entry) }
            raise Invalid, "post-merge mapping does not match occurrence #{id}"
          end
          [ id, deep_copy(mapped) ]
        end
      end

      def snapshot_path_mappings(record)
        record.dig("snapshot", "changed_paths").map do |path|
          { "path" => path, "slice_ids" => [ "unmapped-validation" ] }
        end
      end

      def units(record, mappings)
        chunks = mappings.fetch(record.fetch("occurrence_id")).each_slice(MAX_PATHS).to_a
        chunks.each_with_index.map do |paths, index|
          {
            "occurrence_id" => record.fetch("occurrence_id"),
            "chunk_index" => index + 1, "chunk_count" => chunks.size,
            "repository" => record.dig("snapshot", "repository"),
            "registration" => registration(record),
            "number" => record.dig("snapshot", "number"),
            "merge_sha" => record.dig("snapshot", "merge_sha"),
            "merged_at" => record.dig("snapshot", "merged_at"),
            "path_mappings" => paths
          }
        end
      end

      def registration(record)
        # Repository registration is controller-owned but is not duplicated in
        # the classifier snapshot; scheduler supplies it before claim.
        record.fetch("registration")
      end

      def claimed_chunks(batches)
        batches.flat_map { |batch| batch.fetch("members") }.to_h do |member|
          [ [ member.fetch("occurrence_id"), member.fetch("chunk_index") ], true ]
        end
      end

      def first_unclaimed_unit(record, mappings, claimed)
        units(record, mappings).find do |unit|
          !claimed[[ unit.fetch("occurrence_id"), unit.fetch("chunk_index") ]]
        end
      end

      def select_members(primary, primary_unit, records, mappings, claimed)
        members = [ primary_unit ]
        count = primary_unit.fetch("path_mappings").size
        seed = primary_unit.fetch("path_mappings").flat_map { |mapping| mapping.fetch("slice_ids") }.uniq
        primary_time = Time.iso8601(primary.dig("snapshot", "merged_at"))
        records.each do |record|
          next if record.fetch("occurrence_id") == primary.fetch("occurrence_id")
          next unless record.dig("snapshot", "repository") == primary.dig("snapshot", "repository")
          next if (Time.iso8601(record.dig("snapshot", "merged_at")) - primary_time).abs > WINDOW_SEC
          unit = first_unclaimed_unit(record, mappings, claimed)
          next unless unit
          slices = unit.fetch("path_mappings").flat_map { |mapping| mapping.fetch("slice_ids") }
          next if (slices & seed).empty? || count + unit.fetch("path_mappings").size > MAX_PATHS

          members << unit
          count += unit.fetch("path_mappings").size
          seed |= slices
          break if members.size >= MAX_MEMBERS
        end
        members
      end

      def build_record(members, analysis_sha, now)
        batch_id = batch_id_for(analysis_sha, members)
        primary = members.first
        source = {
          "registration" => primary.fetch("registration"),
          "repository" => primary.fetch("repository"), "number" => primary.fetch("number"),
          "merge_sha" => primary.fetch("merge_sha")
        }
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "batch_id" => batch_id,
          "owner_job_id" => PrManifest.job_id(source: source, identity: "batch:#{batch_id}"),
          "analysis_sha" => analysis_sha, "status" => "claimed", "members" => members,
          "manifest_checksum" => nil, "created_at" => now.iso8601(6), "materialized_at" => nil
        }
      end

      def authoritative_records = each_record.to_a

      def parse_record(bytes, expected_batch_id: nil)
        record = JSON.parse(bytes)
        unless record.is_a?(Hash) && record.keys.sort == RECORD_KEYS.sort &&
               record["schema"] == SCHEMA && record["schema_version"] == SCHEMA_VERSION &&
               DIGEST.match?(record["batch_id"].to_s) &&
               record["owner_job_id"].to_s.match?(/\Apr-[1-9]\d*-[0-9a-f]{16}\z/) &&
               OID.match?(record["analysis_sha"].to_s) &&
               %w[claimed materialized finalized].include?(record["status"]) &&
               record["members"].is_a?(Array) && record["members"].size.between?(1, MAX_MEMBERS)
          raise Invalid, "post-merge batch record is invalid"
        end
        total_paths = 0
        record.fetch("members").each do |member|
          unless member.is_a?(Hash) && member.keys.sort == MEMBER_KEYS.sort &&
                 DIGEST.match?(member["occurrence_id"].to_s) &&
                 member["chunk_index"].is_a?(Integer) && member["chunk_count"].is_a?(Integer) &&
                 member["chunk_index"].between?(1, member["chunk_count"]) &&
                 member["number"].is_a?(Integer) && member["number"].positive? &&
                 member["registration"].is_a?(String) && !member["registration"].empty? &&
                 OID.match?(member["merge_sha"].to_s) &&
                 member["path_mappings"].is_a?(Array) &&
                 member["path_mappings"].size.between?(1, MAX_PATHS) &&
                 member["path_mappings"].map { |mapping| mapping["path"] }.uniq.size ==
                   member["path_mappings"].size &&
                 member["path_mappings"].all? { |item| valid_path_mapping?(item) }
            raise Invalid, "post-merge batch member is invalid"
          end
          Time.iso8601(member.fetch("merged_at"))
          total_paths += member.fetch("path_mappings").size
        end
        raise Invalid, "post-merge batch path bound is exceeded" if total_paths > MAX_PATHS
        member_ids = record.fetch("members").map do |member|
          [ member.fetch("occurrence_id"), member.fetch("chunk_index") ]
        end
        raise Invalid, "post-merge batch repeats a source chunk" unless member_ids.uniq == member_ids

        calculated_id = batch_id_for(record.fetch("analysis_sha"), record.fetch("members"))
        expected_owner = owner_job_id_for(record.fetch("members").first, calculated_id)
        unless record.fetch("batch_id") == calculated_id &&
               (!expected_batch_id || record.fetch("batch_id") == expected_batch_id) &&
               record.fetch("owner_job_id") == expected_owner
          raise Invalid, "post-merge batch identity is invalid"
        end
        Time.iso8601(record.fetch("created_at"))
        if %w[materialized finalized].include?(record.fetch("status"))
          unless DIGEST.match?(record["manifest_checksum"].to_s) && record["materialized_at"]
            raise Invalid, "post-merge batch materialization is incomplete"
          end
          Time.iso8601(record.fetch("materialized_at"))
        elsif record["manifest_checksum"] || record["materialized_at"]
          raise Invalid, "claimed post-merge batch contains materialization fields"
        end
        record
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError => error
        raise Invalid, "post-merge batch record is unreadable (#{error.message})"
      end

      def valid_path_mapping?(entry)
        entry.is_a?(Hash) && entry.keys.sort == PATH_MAPPING_KEYS.sort &&
          PrManifest.valid_relative_path?(entry["path"]) && entry["path"].bytesize <= 4_096 &&
          entry["slice_ids"].is_a?(Array) && entry["slice_ids"].size.between?(1, 32) &&
          entry["slice_ids"].uniq == entry["slice_ids"] &&
          entry["slice_ids"].all? do |id|
            id.is_a?(String) && !id.empty? && id.bytesize <= 256 &&
              id.valid_encoding? && !id.include?("\0")
          end
      end

      def persist(record)
        parse_record(canonical_json(record), expected_batch_id: record.fetch("batch_id"))
        @directory.atomic_write(record_relative(record.fetch("batch_id")), canonical_json(record), mode: 0o600)
      end

      def batch_id_for(analysis_sha, members)
        Digest::SHA256.hexdigest(canonical_json(
          "analysis_sha" => analysis_sha, "members" => members
        ))
      end

      def owner_job_id_for(primary, batch_id)
        PrManifest.job_id(
          source: {
            "registration" => primary.fetch("registration"),
            "repository" => primary.fetch("repository"),
            "number" => primary.fetch("number"),
            "merge_sha" => primary.fetch("merge_sha")
          },
          identity: "batch:#{batch_id}"
        )
      end

      def record_relative(batch_id) = "records/#{batch_id}.json"
      def canonical_json(value) = PrManifest.canonical_json(value)
      def normalize_time(value) = value.utc
      def deep_copy(value) = JSON.parse(JSON.generate(value))
    end
  end
end
