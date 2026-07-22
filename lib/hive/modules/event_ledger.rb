require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/module_package/manifest"
require "hive/stringify_keys"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    class EventLedgerError < Hive::Error; end
    class ConflictingEvent < EventLedgerError; end

    EventResult = Data.define(:status, :event) do
      def created? = status == :created
      def duplicate? = status == :duplicate
    end

    # Strict project-local occurrence ledger. Each event is one immutable,
    # canonical file; the directory fsync is the append commit point. Unlike
    # Hive::Events telemetry, unreadable or conflicting evidence fails closed.
    class EventLedger
      SCHEMA = "hive-module-event".freeze
      SCHEMA_VERSION = 1
      EVENT_NAMES = [ "schedule", *Hive::ModulePackage::Manifest::EVENT_NAMES ].freeze
      MAX_PAYLOAD_BYTES = 64 * 1024

      attr_reader :root, :events_root

      def initialize(root:)
        @root = File.expand_path(root)
        @events_root = File.join(@root, "events")
        FileUtils.mkdir_p(@events_root, mode: 0o700)
        File.chmod(0o700, @events_root)
      rescue SystemCallError => e
        raise EventLedgerError, "module event ledger is unavailable: #{e.message}"
      end

      def record(project_id:, project:, event_name:, occurred_at:, source:, idempotency_key:,
                 payload: {}, recorded_at: Time.now.utc)
        event = build_event(
          project_id: project_id, project: project, event_name: event_name,
          occurred_at: occurred_at, source: source, idempotency_key: idempotency_key,
          payload: payload, recorded_at: recorded_at
        )
        with_lock do
          existing = fetch_unlocked(event.fetch("event_id"))
          if existing
            return EventResult.new(status: :duplicate, event: existing) if equivalent?(existing, event)

            raise ConflictingEvent, "module event idempotency key conflicts with existing occurrence"
          end
          Hive::AtomicFile.write(event_path(event.fetch("event_id")), canonical(event), mode: 0o600)
          Hive::AtomicFile.fsync_directory(events_root)
        end
        EventResult.new(status: :created, event: event.freeze)
      rescue EventLedgerError, Hive::ConfigError
        raise
      rescue SystemCallError, IOError => e
        raise EventLedgerError, "module event could not be persisted: #{e.message}"
      end

      def fetch(event_id)
        with_lock(shared: true) { fetch_unlocked(event_id) }
      end

      def all
        with_lock(shared: true) do
          Dir.glob(File.join(events_root, "evt-*.json")).sort.map do |path|
            parse(File.binread(path), expected_id: File.basename(path, ".json"))
          end.freeze
        end
      end

      private

      def build_event(project_id:, project:, event_name:, occurred_at:, source:,
                      idempotency_key:, payload:, recorded_at:)
        project_id = nonempty(project_id, "project_id")
        project = nonempty(project, "project")
        event_name = event_name.to_s
        raise EventLedgerError, "unsupported module event #{event_name.inspect}" unless EVENT_NAMES.include?(event_name)
        key = nonempty(idempotency_key, "idempotency_key")
        raise EventLedgerError, "module event idempotency key is too long" if key.bytesize > 512
        source = Hive::StringifyKeys.call(source)
        unless source.is_a?(Hash) && source.keys.sort == %w[id type] &&
               source.values.all? { |value| value.is_a?(String) && !value.empty? }
          raise EventLedgerError, "module event source identity is malformed"
        end
        payload = Hive::StringifyKeys.call(payload)
        raise EventLedgerError, "module event payload must be an object" unless payload.is_a?(Hash)
        payload_bytes = canonical(payload)
        raise EventLedgerError, "module event payload is too large" if payload_bytes.bytesize > MAX_PAYLOAD_BYTES
        occurred = iso8601(occurred_at, "occurred_at")
        recorded = iso8601(recorded_at, "recorded_at")
        event_id = "evt-#{::Digest::SHA256.hexdigest([ project_id, event_name, key ].join("\0"))}"
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "event_id" => event_id, "event_name" => event_name,
          "project_id" => project_id, "project" => project,
          "occurred_at" => occurred, "recorded_at" => recorded,
          "source" => source, "idempotency_key" => key, "payload" => payload
        }
      end

      def fetch_unlocked(event_id)
        parse(File.binread(event_path(event_id)), expected_id: event_id)
      rescue Errno::ENOENT
        nil
      end

      def parse(bytes, expected_id:)
        data = JSON.parse(bytes)
        unless bytes == canonical(data) && valid_event?(data) && data["event_id"] == expected_id
          raise EventLedgerError, "module event ledger contains malformed evidence"
        end
        data.freeze
      rescue JSON::ParserError, EncodingError
        raise EventLedgerError, "module event ledger contains malformed evidence"
      end

      def valid_event?(data)
        expected = %w[
          event_id event_name idempotency_key occurred_at payload project project_id
          recorded_at schema schema_version source
        ]
        data.is_a?(Hash) && data.keys.sort == expected && data["schema"] == SCHEMA &&
          data["schema_version"] == SCHEMA_VERSION && EVENT_NAMES.include?(data["event_name"]) &&
          data["event_id"].to_s.match?(/\Aevt-[0-9a-f]{64}\z/) &&
          %w[project project_id idempotency_key].all? { |key| data[key].is_a?(String) && !data[key].empty? } &&
          data["source"].is_a?(Hash) && data["payload"].is_a?(Hash) &&
          Time.iso8601(data.fetch("occurred_at")) && Time.iso8601(data.fetch("recorded_at"))
      rescue ArgumentError, TypeError
        false
      end

      def equivalent?(left, right)
        left.reject { |key, _value| key == "recorded_at" } ==
          right.reject { |key, _value| key == "recorded_at" }
      end

      def event_path(event_id)
        unless event_id.to_s.match?(/\Aevt-[0-9a-f]{64}\z/)
          raise EventLedgerError, "module event id is malformed"
        end
        File.join(events_root, "#{event_id}.json")
      end

      def with_lock(shared: false)
        FileUtils.mkdir_p(root, mode: 0o700)
        File.open(File.join(root, "events.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise EventLedgerError, "module event ledger lock is unavailable: #{e.message}"
      end

      def nonempty(value, label)
        string = value.to_s
        raise EventLedgerError, "module event #{label} must be non-empty" if string.empty?
        string
      end

      def iso8601(value, label)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise EventLedgerError, "module event #{label} must be an ISO 8601 timestamp"
      end

      def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
    end
  end
end
