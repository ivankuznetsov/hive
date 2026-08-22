require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/base_state_store"
require "hive/managed_directory"
require "hive/patrol/fix_admission_adapter"

module Hive
  module Patrol
    class StateStore < BaseStateStore
      FINDING_QUERY_SCHEMA = "hive-patrol-finding-query".freeze
      FINDING_QUERY_SCHEMA_VERSION = 1
      FINDING_QUERY_LIMIT = 25
      FINDING_QUERY_MAX_BYTES = 256 * 1024
      FINDING_QUERY_KEYS = %w[
        counts items schema schema_version total truncated
      ].freeze
      FINDING_QUERY_ITEM_LIMITS = {
        "id" => 128,
        "feature_id" => 128,
        "category" => 64,
        "severity" => 32,
        "confidence" => 32,
        "title" => 512,
        "description" => 4 * 1024,
        "lifecycle_state" => 32,
        "lifecycle_updated_at" => 64
      }.freeze
      attr_reader :patrol_fix_admission_adapter

      def initialize(project_root, hive_state_path: nil,
                     patrol_fix_admission_adapter: nil)
        super(
          project_root,
          state_directory: "patrol",
          collections: %w[features findings runs],
          hive_state_path: hive_state_path
        )
        @cycle_directory = Hive::ManagedDirectory.new(
          root: root,
          label: "ordinary patrol cycle"
        )
        @cycle_lock_owner = nil
        @patrol_fix_admission_adapter = patrol_fix_admission_adapter ||
          Hive::Patrol::FixAdmissionAdapter.for_project(
            project_root: project_root, hive_state_path: hive_state_path
          )
      end

      # The finding query file is a bounded, derived read model. Patrol owns
      # its construction so status consumers never need to parse the complete
      # finding corpus. A dirty marker makes an interrupted writer fail closed
      # until the next Patrol cycle repairs the projection.
      def ensure!
        super
      end

      # One stable installation-local lock spans recovery, suppression reads,
      # agent work, and every resulting effect. Nested collaborators reuse the
      # same lock in one thread; other threads/processes wait on the flock.
      def with_cycle_lock
        owner = [ Process.pid, Thread.current.object_id ]
        return yield if @cycle_lock_owner == owner

        @cycle_directory.prepare!
        @cycle_directory.with_lock("cycle.lock") do
          @cycle_lock_owner = owner
          ensure!
          repair_finding_query_projection!
          yield
        ensure
          @cycle_lock_owner = nil
        end
      end

      # Daemon admission avoids starting a second cycle while one is already
      # mutating the ordinary Patrol store.
      def try_with_cycle_admission
        acquired = false
        value = @cycle_directory.with_lock("cycle.lock", nonblock: true) do
          acquired = true
          yield
        end
        [ acquired, value ]
      end

      def write_features(features)
        supplied = Array(features)
        identities = supplied.map { |feature| feature.id.to_s }
        return [] if identities.empty?

        ids = identities.sort
        if ids.any?(&:empty?) || ids.uniq.size != ids.size
          raise Hive::ConfigError,
                "patrol feature batch identities are malformed"
        end

        supplied.each { |feature| write_record("features", feature) }
        supplied
      end

      def write_finding(finding)
        mark_finding_query_dirty!
        write_record("findings", finding)
        @patrol_fix_admission_adapter.publish_finding!(finding)
      end

      def finding_query_projection
        dirty = @cycle_directory.entry_type(
          "finding-query.dirty", missing: true
        )
        raise Hive::ConfigError, "patrol finding query projection is rebuilding" if dirty

        bytes = @cycle_directory.read(
          "finding-query.json", max_bytes: FINDING_QUERY_MAX_BYTES,
          missing: true
        )
        payload = bytes && JSON.parse(bytes)
        finding_query_projection_valid!(payload)
        payload
      rescue JSON::ParserError, EncodingError, Hive::ManagedDirectory::UnsafeError
        raise_finding_query_unavailable!
      end

      # Writer-side repair only. It may scan the authoritative finding corpus,
      # but no read-only Web or CLI request calls it.
      def rebuild_finding_query_projection!
        mark_finding_query_dirty!
        values = findings
        counts = values.each_with_object(Hash.new(0)) do |finding, result|
          result[finding_lifecycle(finding)] += 1
        end
        ordered = values.sort_by do |finding|
          [ finding_lifecycle(finding) == "active" ? 0 : 1,
            -finding_query_time(finding) ]
        end
        payload = {
          "schema" => FINDING_QUERY_SCHEMA,
          "schema_version" => FINDING_QUERY_SCHEMA_VERSION,
          "total" => values.size,
          "counts" => counts.sort.to_h,
          "items" => ordered.first(FINDING_QUERY_LIMIT).map do |finding|
            finding_query_item(finding)
          end,
          "truncated" => values.size > FINDING_QUERY_LIMIT
        }
        bytes = "#{JSON.pretty_generate(payload)}\n"
        raise_finding_query_unavailable! if bytes.bytesize > FINDING_QUERY_MAX_BYTES

        @cycle_directory.atomic_write(
          "finding-query.json", bytes, mode: 0o600
        )
        @cycle_directory.unlink("finding-query.dirty", missing: true)
        payload
      end

      def findings
        Dir.glob(File.join(root, "findings", "*.json")).sort.filter_map do |path|
          data = read_json(path)
          Finding.from_h(data) unless data.empty?
        rescue KeyError, ArgumentError
          nil
        end
      end

      def transition_finding(finding_or_id, state:, reason:, now: Time.now, superseded_by: nil)
        unless Finding::LIFECYCLE_STATES.include?(state.to_s)
          raise ArgumentError, "unsupported patrol finding lifecycle state #{state.inspect}"
        end

        finding = if finding_or_id.is_a?(Finding)
          finding_or_id
        else
          findings.find { |candidate| candidate.id.to_s == finding_or_id.to_s }
        end
        return unless finding
        return finding if finding.lifecycle_state == state.to_s &&
                          finding.lifecycle_reason == reason.to_s &&
                          finding.superseded_by.to_s == superseded_by.to_s

        finding.lifecycle_state = state.to_s
        finding.lifecycle_reason = reason.to_s
        finding.lifecycle_updated_at = now.utc.iso8601
        finding.superseded_by = superseded_by unless superseded_by.to_s.empty?
        finding.superseded_by = nil unless state.to_s == "superseded"
        write_finding(finding)
      end

      private

      def mark_finding_query_dirty!
        @cycle_directory.atomic_write(
          "finding-query.dirty", "dirty\n", mode: 0o600
        )
      end

      def repair_finding_query_projection!
        finding_query_projection
      rescue Hive::ConfigError
        rebuild_finding_query_projection!
      end

      def finding_lifecycle(finding)
        value = finding.lifecycle_state.to_s
        Hive::Patrol::Finding::LIFECYCLE_STATES.include?(value) ? value : "active"
      end

      def finding_query_item(finding)
        {
          "id" => bounded_finding_query_string(finding.id, 128),
          "feature_id" => bounded_finding_query_string(finding.feature_id, 128),
          "category" => bounded_finding_query_string(finding.category, 64),
          "severity" => bounded_finding_query_string(finding.severity, 32),
          "confidence" => bounded_finding_query_string(finding.confidence, 32),
          "title" => bounded_finding_query_string(finding.title, 512),
          "description" => bounded_finding_query_string(finding.description, 4 * 1024),
          "lifecycle_state" => finding_lifecycle(finding),
          "lifecycle_updated_at" => bounded_finding_query_string(
            finding.lifecycle_updated_at, 64
          )
        }
      end

      def bounded_finding_query_string(value, max_bytes)
        text = value.to_s.encode(
          Encoding::UTF_8, invalid: :replace, undef: :replace, replace: ""
        )
        return text if text.bytesize <= max_bytes

        text.b.byteslice(0, max_bytes).to_s.force_encoding(Encoding::UTF_8).scrub("")
      end

      def finding_query_projection_valid!(payload)
        valid = payload.is_a?(Hash) &&
                payload.keys.sort == FINDING_QUERY_KEYS &&
                payload["schema"] == FINDING_QUERY_SCHEMA &&
                payload["schema_version"] == FINDING_QUERY_SCHEMA_VERSION &&
                payload["total"].is_a?(Integer) && payload["total"] >= 0 &&
                valid_finding_query_counts?(payload["counts"]) &&
                valid_finding_query_items?(payload["items"]) &&
                [ true, false ].include?(payload["truncated"]) &&
                payload["counts"].values.sum == payload["total"] &&
                payload["items"].size == [ payload["total"], FINDING_QUERY_LIMIT ].min &&
                payload["truncated"] == (payload["total"] > FINDING_QUERY_LIMIT)
        raise_finding_query_unavailable! unless valid
      end

      def valid_finding_query_counts?(counts)
        counts.is_a?(Hash) &&
          (counts.keys - Hive::Patrol::Finding::LIFECYCLE_STATES).empty? &&
          counts.values.all? { |value| value.is_a?(Integer) && value >= 0 }
      end

      def valid_finding_query_items?(items)
        items.is_a?(Array) && items.size <= FINDING_QUERY_LIMIT &&
          items.all? do |item|
            item.is_a?(Hash) &&
              item.keys.sort == FINDING_QUERY_ITEM_LIMITS.keys.sort &&
              FINDING_QUERY_ITEM_LIMITS.all? do |key, max_bytes|
                item[key].is_a?(String) && item[key].valid_encoding? &&
                  item[key].bytesize <= max_bytes
              end &&
              Hive::Patrol::Finding::LIFECYCLE_STATES.include?(
                item["lifecycle_state"]
              )
          end
      end

      def raise_finding_query_unavailable!
        raise Hive::ConfigError,
              "patrol finding query projection is unavailable; run a patrol cycle to rebuild it"
      end

      def finding_query_time(finding)
        Time.iso8601(finding.lifecycle_updated_at.to_s).to_f
      rescue ArgumentError
        0.0
      end
    end
  end
end
