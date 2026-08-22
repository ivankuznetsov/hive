require "digest"
require "json"
require "securerandom"
require "time"

require "hive/config"
require "hive/lock"
require "hive/managed_directory"
require "hive/patrol_fix"
require "hive/refactor_patrol/fix_admission_adapter"
require "hive/refactor_patrol/frozen_revision_map_rig"

module Hive
  module RefactorPatrol
    # Independent current-main producer for scheduled Architecture Patrol. It
    # owns only map/cursor/claim state; merged-PR manifests and JobStore are a
    # separate post-merge authority.
    class ScheduledSliceProducer
      SCHEMA = "hive-refactor-patrol-scheduled-slices".freeze
      SCHEMA_VERSION = 1
      STATE_FILE = "state.json".freeze
      LOCK_FILE = "state.lock".freeze
      MAX_STATE_BYTES = 256 * 1024
      MAX_RESULT_BYTES = 4 * 1024 * 1024
      MAX_RESULTS = 10_000
      OID = /\A[0-9a-f]{40,64}\z/.freeze

      Snapshot = Data.define(:analysis_sha, :feature_ids)

      class Snapshotter
        def initialize(rig: FrozenRevisionMapRig.new)
          @rig = rig
        end

        def call(entry:, cfg:)
          mapped = @rig.call(entry: entry, cfg: cfg)
          Snapshot.new(
            analysis_sha: mapped.analysis_sha,
            feature_ids: mapped.features.map { |feature| feature.id.to_s }.uniq.sort.freeze
          )
        end
      end

      def initialize(entry:, cfg:, snapshotter: Snapshotter.new,
                     process_start_reader: Hive::Lock.method(:process_start_time),
                     pid: Process.pid, id_generator: -> { SecureRandom.uuid },
                     admission_adapter: nil)
        @entry = entry
        @cfg = cfg
        @snapshotter = snapshotter
        @process_start_reader = process_start_reader
        @pid = Integer(pid)
        @process_start_time = @process_start_reader.call(@pid).to_s
        raise Hive::ConfigError, "scheduled Architecture Patrol cannot verify owner process" if
          @process_start_time.empty?
        @id_generator = id_generator
        @directory = Hive::ManagedDirectory.new(
          root: File.join(
            entry.fetch("hive_state_path"), "refactor_patrol", "scheduled-discovery"
          ),
          label: "scheduled Architecture Patrol cursor"
        )
        @admission_adapter = admission_adapter || Hive::RefactorPatrol::FixAdmissionAdapter.for_project(
          project_root: entry.fetch("path"),
          hive_state_path: entry.fetch("hive_state_path")
        )
      end

      def claim(now: Time.now.utc)
        @directory.prepare!
        @directory.with_lock(LOCK_FILE) { replay_unconsumed_results(now) }

        snapshot = @snapshotter.call(entry: @entry, cfg: @cfg)
        validate_snapshot!(snapshot)
        return nil if snapshot.feature_ids.empty?

        @directory.with_lock(LOCK_FILE) do
          state = load_state
          return nil if live_claim?(state["claim"])

          feature_id, sweep_generation = select_feature(
            snapshot.feature_ids, state["cursor"], state.fetch("sweep_generation")
          )
          claim = {
            "id" => @id_generator.call.to_s,
            "project_id" => @entry.fetch("project_id").to_s,
            "analysis_sha" => snapshot.analysis_sha,
            "feature_id" => feature_id,
            "sweep_generation" => sweep_generation,
            "map_digest" => Digest::SHA256.hexdigest(snapshot.feature_ids.join("\0")),
            "claimed_at" => normalize_time(now).iso8601(6),
            "owner_pid" => @pid,
            "owner_process_start_time" => @process_start_time
          }
          state["claim"] = claim
          state["updated_at"] = normalize_time(now).iso8601(6)
          persist(state)
          claim.freeze
        end
      end

      def complete(claim_id:, result:, now: Time.now.utc)
        mutate_claim(claim_id, now: now) do |state, claim|
          record = build_result_record(claim, result, now)
          record = persist_result(record)
          publish_admission(record)
          mark_result_consumed(record, now)
          state["cursor"] = claim.fetch("feature_id")
          state["sweep_generation"] = claim.fetch("sweep_generation")
          state["claim"] = nil
        end
      end

      def release(claim_id:, now: Time.now.utc)
        mutate_claim(claim_id, now: now) { |state, _claim| state["claim"] = nil }
      end

      # Bounded retained history of scheduled discovery results.
      def each_result
        return enum_for(__method__) unless block_given?

        @directory.prepare!
        @directory.with_lock(LOCK_FILE, shared: true) do
          result_records.each { |record| yield record }
        end
      rescue JSON::ParserError => e
        raise Hive::ConfigError, "scheduled Architecture Patrol result is unreadable: #{e.message}"
      end

      private

      def result_records
        @directory.each_child("results", missing: true).to_a
          .select { |name| /\A[0-9a-f]{64}\.json\z/.match?(name) }.sort.map do |name|
            bytes = @directory.read("results/#{name}", max_bytes: MAX_RESULT_BYTES)
            JSON.parse(bytes).tap { |record| validate_result_record!(record) }
          end
      end

      def replay_unconsumed_results(now)
        result_records.each do |record|
          next if record["consumed_at"]

          publish_admission(record)
          mark_result_consumed(record, now)
        end
      end

      def mutate_claim(claim_id, now:)
        @directory.prepare!
        @directory.with_lock(LOCK_FILE) do
          state = load_state
          claim = state["claim"]
          return false unless claim && claim.fetch("id") == claim_id.to_s
          return false unless claim.fetch("owner_pid") == @pid &&
                              claim.fetch("owner_process_start_time") == @process_start_time

          yield state, claim
          state["updated_at"] = normalize_time(now).iso8601(6)
          persist(state)
          true
        end
      end

      def select_feature(ids, cursor, sweep_generation)
        return [ ids.first, sweep_generation ] if cursor.to_s.empty?

        next_id = ids.find { |id| id > cursor }
        return [ next_id, sweep_generation ] if next_id

        [ ids.first, sweep_generation + 1 ]
      end

      def build_result_record(claim, result, now)
        report = Hive::PatrolFix.deep_copy(result)
        unless report.is_a?(Hash) && report["schema"] == "hive-refactor-patrol" &&
               report["schema_version"] == 4 && report["ok"] == true &&
               report["review_complete"] == true &&
               report["last_scanned_sha"] == claim.fetch("analysis_sha") &&
               Array(report["review_errors"]).empty?
          raise Hive::ConfigError, "scheduled Architecture Patrol result is incomplete"
        end
        dispositions = %w[fix discuss dismiss].to_h do |route|
          items = Array(report.fetch(route))
          unless items.size <= 256 && items.all? do |item|
            item.is_a?(Hash) && item["route"] == route &&
              item["feature_id"].to_s == claim.fetch("feature_id")
          end
            raise Hive::ConfigError, "scheduled Architecture Patrol dispositions are invalid"
          end
          [ route, items ]
        end
        feature_result = Array(report.fetch("feature_results")).find do |item|
          item["feature_id"].to_s == claim.fetch("feature_id")
        end
        unless feature_result && feature_result["complete"] == true
          raise Hive::ConfigError, "scheduled Architecture Patrol feature result is incomplete"
        end

        stable = Digest::SHA256.hexdigest(
          [ claim.fetch("project_id"), claim.fetch("analysis_sha"),
            claim.fetch("feature_id"), claim.fetch("sweep_generation") ].join("\0")
        )
        paths = dispositions.values.flatten.flat_map do |item|
          Array(item.dig("thesis", "feature_boundary", "owned_files"))
        end.map(&:to_s).uniq.sort
        {
          "schema" => "hive-refactor-patrol-scheduled-result",
          "schema_version" => 1,
          "occurrence_id" => "architecture-scheduled:#{stable}",
          "job_id" => "scheduled-#{stable}",
          "project_id" => claim.fetch("project_id"),
          "analysis_sha" => claim.fetch("analysis_sha"),
          "feature_id" => claim.fetch("feature_id"),
          "sweep_generation" => claim.fetch("sweep_generation"),
          "map_digest" => claim.fetch("map_digest"),
          "source" => {
            "lane" => "scheduled", "changed_paths" => paths,
            "claimed_at" => claim.fetch("claimed_at")
          },
          "created_at" => normalize_time(now).iso8601(6),
          "consumed_at" => nil,
          "feature_results" => [ feature_result ],
          "dispositions" => dispositions,
          "report" => report
        }
      rescue JSON::GeneratorError, KeyError => e
        raise Hive::ConfigError, "scheduled Architecture Patrol result is invalid: #{e.message}"
      end

      def persist_result(record)
        validate_result_record!(record)
        @directory.ensure_directory("results")
        digest = record.fetch("occurrence_id").delete_prefix("architecture-scheduled:")
        relative = "results/#{digest}.json"
        content = "#{JSON.pretty_generate(record)}\n"
        raise Hive::ConfigError, "scheduled Architecture Patrol result is too large" if
          content.bytesize > MAX_RESULT_BYTES
        existing = @directory.read(relative, max_bytes: MAX_RESULT_BYTES, missing: true)
        if existing
          parsed = JSON.parse(existing)
          validate_result_record!(parsed)
          unless stable_result_content(parsed) == stable_result_content(record)
            raise Hive::ConfigError, "scheduled Architecture Patrol result identity conflicts"
          end
          return parsed
        end
        compact_results_for_capacity!

        @directory.atomic_write(relative, content, mode: 0o600)
        record
      rescue JSON::ParserError => e
        raise Hive::ConfigError, "scheduled Architecture Patrol result is unreadable: #{e.message}"
      end

      def stable_result_content(record)
        record.reject { |key, _value| %w[created_at consumed_at].include?(key) }.tap do |copy|
          copy["source"] = copy.fetch("source").reject { |key, _value| key == "claimed_at" }
        end
      end

      def mark_result_consumed(record, now)
        return record if record["consumed_at"]

        consumed = Hive::PatrolFix.deep_copy(record)
        consumed["consumed_at"] = normalize_time(now).iso8601(6)
        validate_result_record!(consumed)
        digest = consumed.fetch("occurrence_id").delete_prefix("architecture-scheduled:")
        content = "#{JSON.pretty_generate(consumed)}\n"
        raise Hive::ConfigError, "scheduled Architecture Patrol result is too large" if
          content.bytesize > MAX_RESULT_BYTES
        @directory.atomic_write(
          "results/#{digest}.json", content, mode: 0o600,
          max_existing_bytes: MAX_RESULT_BYTES
        )
        consumed
      end

      def compact_results_for_capacity!
        names = @directory.each_child("results", missing: true).to_a
          .select { |name| /\A[0-9a-f]{64}\.json\z/.match?(name) }
        required = names.size - MAX_RESULTS + 1
        return if required <= 0

        removable = names.filter_map do |name|
          relative = "results/#{name}"
          bytes = @directory.read(relative, max_bytes: MAX_RESULT_BYTES)
          record = JSON.parse(bytes)
          validate_result_record!(record)
          [ record.fetch("consumed_at"), record.fetch("created_at"), name, bytes ] if
            record["consumed_at"]
        end.sort
        if removable.size < required
          raise Hive::ConfigError,
                "scheduled Architecture Patrol result capacity contains unconsumed work"
        end
        removable.first(required).each do |_consumed_at, _created_at, name, bytes|
          @directory.unlink(
            "results/#{name}", expected_digest: Digest::SHA256.hexdigest(bytes),
            max_bytes: MAX_RESULT_BYTES
          )
        end
      end

      def publish_admission(record)
        %w[fix discuss dismiss].each do |route|
          record.dig("dispositions", route).each do |disposition|
            @admission_adapter.publish_disposition!(record, disposition)
          end
        end
      end

      def validate_result_record!(record)
        expected = %w[analysis_sha consumed_at created_at dispositions feature_id feature_results job_id map_digest occurrence_id project_id report schema schema_version source sweep_generation]
        source = record["source"] if record.is_a?(Hash)
        report = record["report"] if record.is_a?(Hash)
        dispositions = record["dispositions"] if record.is_a?(Hash)
        feature_results = record["feature_results"] if record.is_a?(Hash)
        valid = record.is_a?(Hash) && record.keys.sort == expected &&
          record["schema"] == "hive-refactor-patrol-scheduled-result" &&
          record["schema_version"] == 1 && record["project_id"] == @entry.fetch("project_id").to_s &&
          OID.match?(record["analysis_sha"].to_s) && valid_id?(record["feature_id"]) &&
          record["sweep_generation"].is_a?(Integer) && record["sweep_generation"] >= 0 &&
          /\A[0-9a-f]{64}\z/.match?(record["map_digest"].to_s) && valid_time?(record["created_at"]) &&
          (record["consumed_at"].nil? || valid_time?(record["consumed_at"])) &&
          valid_result_source?(source) && valid_result_report?(report, record) &&
          dispositions.is_a?(Hash) && dispositions.keys.sort == %w[discuss dismiss fix] &&
          %w[fix discuss dismiss].all? do |route|
            items = dispositions[route]
            items.is_a?(Array) && items.size <= 256 && items.all? do |item|
              item.is_a?(Hash) && item["route"] == route &&
                item["feature_id"].to_s == record["feature_id"]
            end && report[route] == items
          end &&
          feature_results.is_a?(Array) && feature_results.size == 1 &&
          feature_results.fetch(0).is_a?(Hash) &&
          feature_results.fetch(0)["feature_id"].to_s == record["feature_id"] &&
          feature_results.fetch(0)["complete"] == true &&
          report["feature_results"] == feature_results
        raise Hive::ConfigError, "scheduled Architecture Patrol result schema is invalid" unless valid

        stable = Digest::SHA256.hexdigest(
          [ record.fetch("project_id"), record.fetch("analysis_sha"),
            record.fetch("feature_id"), record.fetch("sweep_generation") ].join("\0")
        )
        unless record["occurrence_id"] == "architecture-scheduled:#{stable}" &&
               record["job_id"] == "scheduled-#{stable}"
          raise Hive::ConfigError, "scheduled Architecture Patrol result identity is invalid"
        end
        true
      end

      def valid_result_source?(source)
        source.is_a?(Hash) && source.keys.sort == %w[changed_paths claimed_at lane] &&
          source["lane"] == "scheduled" && valid_time?(source["claimed_at"]) &&
          source["changed_paths"].is_a?(Array) && source["changed_paths"].size <= 10_000 &&
          source["changed_paths"].all? { |path| path.is_a?(String) && path.bytesize <= 4096 } &&
          source["changed_paths"] == source["changed_paths"].uniq.sort
      end

      def valid_result_report?(report, record)
        report.is_a?(Hash) && report["schema"] == "hive-refactor-patrol" &&
          report["schema_version"] == 4 && report["ok"] == true &&
          report["review_complete"] == true &&
          report["last_scanned_sha"] == record["analysis_sha"] &&
          report["review_errors"].is_a?(Array) && report["review_errors"].empty?
      end

      def live_claim?(claim)
        return false unless claim

        @process_start_reader.call(claim.fetch("owner_pid")).to_s ==
          claim.fetch("owner_process_start_time")
      rescue StandardError
        true
      end

      def validate_snapshot!(snapshot)
        unless snapshot.is_a?(Snapshot) && OID.match?(snapshot.analysis_sha.to_s) &&
               snapshot.feature_ids.is_a?(Array) && snapshot.feature_ids.size <= 10_000 &&
               snapshot.feature_ids.all? do |id|
                 id.is_a?(String) && !id.empty? && id.bytesize <= 256
               end && snapshot.feature_ids == snapshot.feature_ids.uniq.sort
          raise Hive::ConfigError, "scheduled Architecture Patrol map is invalid"
        end
      end

      def load_state
        bytes = @directory.read(STATE_FILE, max_bytes: MAX_STATE_BYTES, missing: true)
        return empty_state unless bytes

        state = JSON.parse(bytes)
        validate_state!(state)
        state
      rescue JSON::ParserError => e
        raise Hive::ConfigError, "scheduled Architecture Patrol cursor is unreadable: #{e.message}"
      end

      def empty_state
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "project_id" => @entry.fetch("project_id").to_s,
          "cursor" => nil, "sweep_generation" => 0,
          "claim" => nil, "updated_at" => nil
        }
      end

      def persist(state)
        validate_state!(state)
        content = "#{JSON.pretty_generate(state)}\n"
        raise Hive::ConfigError, "scheduled Architecture Patrol cursor is too large" if
          content.bytesize > MAX_STATE_BYTES
        @directory.atomic_write(
          STATE_FILE, content, mode: 0o600, max_existing_bytes: MAX_STATE_BYTES
        )
      end

      def validate_state!(state)
        unless state.is_a?(Hash) &&
               state.keys.sort == %w[claim cursor project_id schema schema_version sweep_generation updated_at] &&
               state["schema"] == SCHEMA && state["schema_version"] == SCHEMA_VERSION &&
               state["project_id"] == @entry.fetch("project_id").to_s &&
               (state["cursor"].nil? || valid_id?(state["cursor"])) &&
               state["sweep_generation"].is_a?(Integer) && state["sweep_generation"] >= 0 &&
               (state["updated_at"].nil? || valid_time?(state["updated_at"])) &&
               (state["claim"].nil? || valid_claim?(state["claim"]))
          raise Hive::ConfigError, "scheduled Architecture Patrol cursor schema is invalid"
        end
        true
      end

      def valid_claim?(claim)
        claim.is_a?(Hash) &&
          claim.keys.sort == %w[analysis_sha claimed_at feature_id id map_digest owner_pid owner_process_start_time project_id sweep_generation] &&
          valid_id?(claim["id"]) && claim["project_id"] == @entry.fetch("project_id").to_s &&
          OID.match?(claim["analysis_sha"].to_s) && valid_id?(claim["feature_id"]) &&
          claim["sweep_generation"].is_a?(Integer) && claim["sweep_generation"] >= 0 &&
          /\A[0-9a-f]{64}\z/.match?(claim["map_digest"].to_s) &&
          valid_time?(claim["claimed_at"]) && claim["owner_pid"].is_a?(Integer) &&
          claim["owner_pid"] > 1 && !claim["owner_process_start_time"].to_s.empty?
      end

      def valid_id?(value)
        value.is_a?(String) && !value.empty? && value.bytesize <= 256
      end

      def valid_time?(value)
        normalize_time(value)
        true
      rescue ArgumentError
        false
      end

      def normalize_time(value)
        value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
      end
    end
  end
end
