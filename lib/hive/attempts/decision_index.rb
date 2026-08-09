require "date"
require "json"
require "time"
require "hive/attempts/point_storage"
require "hive/attempts/record"

module Hive
  module Attempts
    # Point-addressed decision cells used by later admission/reconciliation
    # work. Each compound key is digest-addressed and embedded in its payload;
    # no operation enumerates historical cells.
    class DecisionIndex
      SCHEMA = "hive-attempt-decision-index".freeze
      SCHEMA_VERSION = 1
      MAX_ENTRY_BYTES = 2 * 1024 * 1024
      MAX_DAILY_ATTEMPTS = 10_000
      TERMINAL_REQUEST = "terminal-request".freeze
      SUCCESSFUL_OWNER = "successful-owner".freeze
      UNRESOLVED_LOSS = "unresolved-loss".freeze
      SUCCESSOR = "successor".freeze
      DAILY_ACCOUNTING = "daily-accounting".freeze
      ENTRY_KEYS = %w[kind key schema schema_version value].freeze

      attr_reader :root

      def initialize(root:, create_directories: true)
        @storage = PointStorage.new(
          root: root,
          label: "attempt decision indexes",
          create_directories: create_directories
        )
        @root = @storage.root
      end

      def record_terminal(record)
        terminal!(record)
        update_ordered(
          TERMINAL_REQUEST,
          request_key(record["request_id"]),
          ordered_value(record).merge("outcome" => record.outcome)
        )
        return record unless record.outcome == "succeeded"

        update_ordered(
          SUCCESSFUL_OWNER,
          semantic_key(record.task_generation, record.subject),
          ordered_value(record)
        )
        record
      end

      def terminal_attempt_id(request_id:)
        value = read_value(TERMINAL_REQUEST, request_key(request_id))
        value && value.fetch("attempt_id")
      end

      def successful_attempt_id(task_generation:, subject:)
        value = read_value(
          SUCCESSFUL_OWNER,
          semantic_key(task_generation, subject)
        )
        value && value.fetch("attempt_id")
      end

      def record_unresolved_loss(record)
        unless record.is_a?(Record) && record.state == "lost"
          raise StoreError, "unresolved-loss index requires a lost schema-v3 record"
        end

        key = semantic_key(record.task_generation, record.subject)
        candidate = ordered_value(record).merge("resolved_by" => nil)
        update_entry(UNRESOLVED_LOSS, key) do |current|
          value = current && current.fetch("value")
          if value && (order(value) <=> order(candidate)) >= 0
            value
          else
            candidate
          end
        end
        record
      end

      def unresolved_loss_attempt_id(task_generation:, subject:)
        value = read_value(
          UNRESOLVED_LOSS,
          semantic_key(task_generation, subject)
        )
        return nil if value.nil? || value["resolved_by"]

        value.fetch("attempt_id")
      end

      def record_successor(record)
        unless record.is_a?(Record) && !record["predecessor_attempt_id"].to_s.empty?
          raise StoreError, "successor index requires a predecessor-bound schema-v3 record"
        end

        predecessor = record["predecessor_attempt_id"]
        key = predecessor_key(predecessor)
        value = ordered_value(record)
        update_entry(SUCCESSOR, key) do |current|
          if current && current.fetch("value") != value
            raise StoreError, "attempt predecessor has conflicting successors"
          end
          value
        end

        loss_key = semantic_key(record.task_generation, record.subject)
        update_entry(UNRESOLVED_LOSS, loss_key) do |current|
          next nil unless current

          existing = current.fetch("value")
          next existing unless existing["attempt_id"] == predecessor

          existing.merge("resolved_by" => record.attempt_id)
        end
        record
      end

      def successor_attempt_id(predecessor_attempt_id:)
        value = read_value(
          SUCCESSOR,
          predecessor_key(predecessor_attempt_id)
        )
        value && value.fetch("attempt_id")
      end

      def record_acceptance(record)
        record!(record)
        date = accepted_date(record)
        key = accounting_key(record["project"], date)
        update_entry(DAILY_ACCOUNTING, key) do |current|
          attempts = current ? current.fetch("value").fetch("attempts").dup : {}
          existing = attempts[record.attempt_id]
          candidate = {
            "accepted_at" => record["accepted_at"],
            "refunded" => false
          }
          if existing && existing != candidate && existing != candidate.merge("refunded" => true)
            raise StoreError, "daily accounting attempt conflicts with its accepted identity"
          end
          attempts[record.attempt_id] ||= candidate
          if attempts.size > MAX_DAILY_ATTEMPTS
            raise StoreError, "daily accounting index exceeds its bounded shard"
          end
          { "attempts" => attempts }
        end
        record
      end

      def refund_tempfail(record)
        terminal!(record)
        unless record.receipt["exit_status"] == Hive::ExitCodes::TEMPFAIL
          raise StoreError, "daily accounting refund requires a TEMPFAIL receipt"
        end

        key = accounting_key(record["project"], accepted_date(record))
        update_entry(DAILY_ACCOUNTING, key) do |current|
          unless current
            raise StoreError, "daily accounting acceptance is missing"
          end

          attempts = current.fetch("value").fetch("attempts").dup
          acceptance = attempts[record.attempt_id]
          unless acceptance && acceptance["accepted_at"] == record["accepted_at"]
            raise StoreError, "daily accounting acceptance is missing"
          end
          attempts[record.attempt_id] = acceptance.merge("refunded" => true)
          { "attempts" => attempts }
        end
        record
      end

      def daily_count(project:, date:)
        value = read_value(
          DAILY_ACCOUNTING,
          accounting_key(project, date_value(date))
        )
        return 0 unless value

        value.fetch("attempts").count do |_attempt_id, acceptance|
          acceptance["refunded"] == false
        end
      end

      def path_for(kind, key)
        @storage.path_for(kind, StorageKey.normalize(key))
      end

      private

      def update_ordered(kind, key, candidate)
        update_entry(kind, key) do |current|
          existing = current && current.fetch("value")
          if existing && (order(existing) <=> order(candidate)) >= 0
            existing
          else
            candidate
          end
        end
      end

      def update_entry(kind, key)
        normalized_key = StorageKey.normalize(key)
        @storage.synchronize(kind, normalized_key) do
          bytes = @storage.read(kind, normalized_key, max_bytes: MAX_ENTRY_BYTES)
          current = bytes && parse_entry(bytes, expected_kind: kind, expected_key: normalized_key)
          value = yield(current)
          next current if current && current.fetch("value") == value
          next nil if current.nil? && value.nil?

          payload = {
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "kind" => kind,
            "key" => normalized_key,
            "value" => value
          }
          replacement = StorageKey.dump(payload)
          raise StoreError, "attempt decision index entry is too large" if replacement.bytesize > MAX_ENTRY_BYTES

          @storage.write(
            kind,
            normalized_key,
            replacement,
            expected_bytes: bytes,
            max_existing_bytes: MAX_ENTRY_BYTES
          )
          payload
        end
      end

      def read_value(kind, key)
        normalized_key = StorageKey.normalize(key)
        bytes = @storage.read(kind, normalized_key, max_bytes: MAX_ENTRY_BYTES)
        return nil unless bytes

        parse_entry(
          bytes,
          expected_kind: kind,
          expected_key: normalized_key
        ).fetch("value")
      end

      def parse_entry(bytes, expected_kind:, expected_key:)
        payload = JSON.parse(bytes)
        valid = payload.is_a?(Hash) &&
          payload.keys.sort == ENTRY_KEYS.sort &&
          payload["schema"] == SCHEMA &&
          payload["schema_version"] == SCHEMA_VERSION &&
          payload["kind"] == expected_kind &&
          payload["key"] == expected_key &&
          bytes == StorageKey.dump(payload) &&
          payload["value"].is_a?(Hash)
        raise StoreError, "attempt decision index entry is corrupt or colliding" unless valid

        validate_value!(expected_kind, payload.fetch("value"))

        payload
      rescue JSON::ParserError, EncodingError, ArgumentError, TypeError, KeyError
        raise StoreError, "attempt decision index entry is corrupt or colliding"
      end

      def validate_value!(kind, value)
        case kind
        when TERMINAL_REQUEST
          ordered_value_shape!(value, extra_keys: [ "outcome" ])
          raise StoreError unless Record::TERMINAL_OUTCOMES.include?(value["outcome"])
        when SUCCESSFUL_OWNER, SUCCESSOR
          ordered_value_shape!(value)
        when UNRESOLVED_LOSS
          ordered_value_shape!(value, extra_keys: [ "resolved_by" ])
          resolved_by = value["resolved_by"]
          StorageKey.string(resolved_by) if resolved_by
        when DAILY_ACCOUNTING
          attempts = value["attempts"]
          raise StoreError unless value.keys == [ "attempts" ] && attempts.is_a?(Hash)
          raise StoreError if attempts.size > MAX_DAILY_ATTEMPTS

          attempts.each do |attempt_id, acceptance|
            StorageKey.string(attempt_id)
            valid = acceptance.is_a?(Hash) &&
              acceptance.keys.sort == %w[accepted_at refunded] &&
              (acceptance["refunded"] == true || acceptance["refunded"] == false)
            raise StoreError unless valid

            Time.iso8601(acceptance.fetch("accepted_at"))
          end
        else
          raise StoreError
        end
        true
      rescue StoreError
        raise StoreError, "attempt decision index entry is corrupt or colliding"
      rescue ArgumentError, TypeError, KeyError
        raise StoreError, "attempt decision index entry is corrupt or colliding"
      end

      def ordered_value_shape!(value, extra_keys: [])
        keys = %w[accepted_at attempt_id lease_version] + extra_keys
        raise StoreError unless value.keys.sort == keys.sort

        StorageKey.string(value.fetch("attempt_id"))
        Time.iso8601(value.fetch("accepted_at"))
        lease_version = value.fetch("lease_version")
        raise StoreError unless lease_version.is_a?(Integer) && lease_version >= 0
      end

      def request_key(request_id) = { "request_id" => StorageKey.string(request_id) }

      def predecessor_key(attempt_id)
        { "predecessor_attempt_id" => StorageKey.string(attempt_id) }
      end

      def semantic_key(task_generation, subject)
        {
          "task_generation" => StorageKey.string(task_generation),
          "subject" => StorageKey.normalize(subject)
        }
      end

      def accounting_key(project, date)
        {
          "project" => StorageKey.string(project),
          "utc_date" => date_value(date).iso8601
        }
      end

      def date_value(value)
        return value if value.is_a?(Date)

        Date.iso8601(value.to_s)
      rescue Date::Error, ArgumentError
        raise StoreError, "daily accounting date is invalid"
      end

      def accepted_date(record)
        Time.iso8601(record["accepted_at"]).utc.to_date
      rescue ArgumentError, TypeError
        raise StoreError, "attempt accepted_at is invalid"
      end

      def ordered_value(record)
        {
          "attempt_id" => record.attempt_id,
          "accepted_at" => record["accepted_at"],
          "lease_version" => record.lease_version
        }
      end

      def order(value)
        [ value.fetch("accepted_at"), value.fetch("lease_version"), value.fetch("attempt_id") ]
      end

      def record!(record)
        return record if record.is_a?(Record)

        raise StoreError, "attempt decision index requires a schema-v3 record"
      end

      def terminal!(record)
        record!(record)
        return record if record.state == "terminal"

        raise StoreError, "terminal decision index requires a terminal schema-v3 record"
      end
    end
  end
end
