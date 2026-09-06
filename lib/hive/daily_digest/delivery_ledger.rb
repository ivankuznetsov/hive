require "date"
require "fileutils"
require "json"
require "objspace"
require "securerandom"
require "time"
require "hive/atomic_file"
require "hive/daily_digest"
require "hive/daily_digest/record"
require "hive/lock"
require "hive/paths"
require "hive/process_kill"

module Hive
  module DailyDigest
    # Durable intent/outcome state around the one externally visible Telegram
    # effect. The ledger is independent from record pruning and never stores a
    # token, message body, or secondary broadcast recipient.
    class DeliveryLedger
      class Error < DailyDigest::Error; end
      class Conflict < Error; end
      class InvalidTransition < Error; end

      OUTCOMES = %w[prepared sending sent suppressed_empty failed unknown].freeze
      TERMINAL_OUTCOMES = %w[sent suppressed_empty unknown].freeze
      MAX_AUTOMATIC_ATTEMPTS = 3
      Preparation = Data.define(:action, :receipt)

      attr_reader :root

      def initialize(root: Hive::Paths.daily_digest_delivery_root,
                     process_identity: nil, process_alive: nil)
        @root = File.expand_path(root)
        @process_identity = process_identity || lambda do
          [ Process.pid, Hive::Lock.process_start_time(Process.pid) ]
        end
        @process_alive = process_alive || method(:matching_process_alive?)
        @preparer_ids = ObjectSpace::WeakMap.new
      end

      def prepare(local_date:, record_id:, amendment_frontier:, payload_hash:,
                  destination_chat_id:, now:, retry_requested: false)
        date = normalize_date(local_date)
        synchronize do
          current = read_unlocked(date)
          if current
            validate_identity!(current, record_id: record_id, destination_chat_id: destination_chat_id)
            if current.fetch("outcome") == "sending"
              return Preparation.new(action: :in_flight, receipt: current) if sender_alive?(current)

              current = promote_sending_unlocked(current, now: now)
            end
            action = preparation_action(current, retry_requested: retry_requested)
            if action == :resume
              unless prepared_owned?(current)
                return Preparation.new(action: :in_flight, receipt: current) if preparer_alive?(current)
              end
              current = refresh_prepared_unlocked(
                current, amendment_frontier: amendment_frontier,
                payload_hash: payload_hash, now: now
              )
              return Preparation.new(action: :send, receipt: current)
            end
            return Preparation.new(action: action, receipt: current) unless action == :send
          end

          attempt = current ? current.fetch("attempt").to_i + 1 : 1
          timestamp = normalize_time(now)
          receipt = (current || {
            "schema" => "hive-digest-delivery-receipt",
            "schema_version" => 1,
            "local_date" => date,
            "record_id" => normalize_digest(record_id, "record id"),
            "destination_chat_id" => normalize_chat_id(destination_chat_id),
            "history" => []
          }).merge(
            "amendment_frontier" => normalize_digest(amendment_frontier, "amendment frontier"),
            "payload_hash" => normalize_digest(payload_hash, "payload hash"),
            "attempt" => attempt,
            "outcome" => "prepared",
            "prepared_at" => timestamp,
            "updated_at" => timestamp,
            "operator_retry" => retry_requested == true,
            "reason_code" => nil
          ).merge(preparer_fields)
          receipt["history"] = Array(receipt["history"]) + [
            history_entry(attempt: attempt, outcome: "prepared", at: timestamp,
                          operator_retry: retry_requested == true)
          ]
          receipt = write_unlocked(date, receipt)
          Preparation.new(action: :send, receipt: receipt)
        end
      end

      def mark_sending(local_date, attempt:, now:)
        pid, process_start_time = @process_identity.call
        transition(
          local_date, attempt: attempt, from: [ "prepared" ], to: "sending", now: now,
          required_preparer_id: preparer_id,
          additions: {
            "sender_pid" => Integer(pid),
            "sender_process_start_time" => process_start_time&.to_s
          }
        )
      rescue ArgumentError, TypeError
        raise InvalidTransition, "digest delivery sender identity is invalid"
      end

      def mark_sent(local_date, attempt:, now:)
        transition(local_date, attempt: attempt, from: [ "sending" ], to: "sent", now: now)
      end

      def mark_suppressed(local_date, attempt:, now:)
        transition(
          local_date, attempt: attempt, from: [ "prepared" ], to: "suppressed_empty", now: now,
          required_preparer_id: preparer_id
        )
      end

      def mark_failed(local_date, attempt:, now:, reason_code:)
        transition(
          local_date, attempt: attempt, from: [ "sending" ], to: "failed", now: now,
          reason_code: reason_code
        )
      end

      def mark_unknown(local_date, attempt:, now:, reason_code:)
        transition(
          local_date, attempt: attempt, from: [ "sending" ], to: "unknown", now: now,
          reason_code: reason_code
        )
      end

      def read(local_date)
        date = normalize_date(local_date)
        synchronize(shared: true) { read_unlocked(date) }
      end

      def reconcile_interrupted(now:)
        return [] unless Dir.exist?(root)

        synchronize do
          receipt_dates.filter_map do |date|
            receipt = read_unlocked(date)
            next unless receipt&.fetch("outcome") == "sending"
            next if sender_alive?(receipt)

            promote_sending_unlocked(receipt, now: now)
          end
        end
      end

      private

      def preparation_action(receipt, retry_requested:)
        outcome = receipt.fetch("outcome")
        # No external effect has started while an intent is merely prepared.
        # Resume the same attempt after a missing token/configuration error;
        # only definite transport failures or explicit retries allocate a new
        # attempt identity.
        return :resume if outcome == "prepared"
        return :duplicate if %w[sent suppressed_empty].include?(outcome)
        return :unknown if outcome == "unknown" && !retry_requested
        if outcome == "failed" && !retry_requested &&
           receipt.fetch("attempt").to_i >= MAX_AUTOMATIC_ATTEMPTS
          return :failed
        end

        :send
      end

      def promote_sending_unlocked(receipt, now:)
        transition_unlocked(
          receipt, attempt: receipt.fetch("attempt"), from: [ "sending" ], to: "unknown",
          now: now, reason_code: "interrupted_send"
        )
      end

      def refresh_prepared_unlocked(receipt, amendment_frontier:, payload_hash:, now:)
        timestamp = normalize_time(now)
        updated = receipt.merge(
          "amendment_frontier" => normalize_digest(amendment_frontier, "amendment frontier"),
          "payload_hash" => normalize_digest(payload_hash, "payload hash"),
          "prepared_at" => timestamp,
          "updated_at" => timestamp
        ).merge(preparer_fields)
        write_unlocked(receipt.fetch("local_date"), updated)
      end

      def transition(local_date, attempt:, from:, to:, now:, reason_code: nil, additions: {},
                     required_preparer_id: nil)
        date = normalize_date(local_date)
        synchronize do
          receipt = read_unlocked(date)
          raise InvalidTransition, "digest delivery #{date} has no prepared intent" unless receipt

          transition_unlocked(
            receipt, attempt: attempt, from: from, to: to, now: now,
            reason_code: reason_code, additions: additions,
            required_preparer_id: required_preparer_id
          )
        end
      end

      def transition_unlocked(receipt, attempt:, from:, to:, now:, reason_code: nil,
                              additions: {}, required_preparer_id: nil)
        unless OUTCOMES.include?(to)
          raise InvalidTransition, "unknown digest delivery outcome #{to.inspect}"
        end
        unless receipt.fetch("attempt").to_i == Integer(attempt) && from.include?(receipt.fetch("outcome"))
          raise InvalidTransition,
                "digest delivery transition #{receipt.fetch('outcome')} -> #{to} is stale"
        end
        if required_preparer_id && receipt["preparer_id"] != required_preparer_id
          raise InvalidTransition, "digest delivery preparation ownership is stale"
        end

        timestamp = normalize_time(now)
        updated = receipt.merge(additions).merge(
          "outcome" => to, "updated_at" => timestamp, "reason_code" => bounded_reason(reason_code)
        )
        updated["history"] = Array(receipt["history"]) + [
          history_entry(attempt: attempt, outcome: to, at: timestamp, reason_code: reason_code)
        ]
        write_unlocked(receipt.fetch("local_date"), updated)
      rescue ArgumentError, TypeError
        raise InvalidTransition, "digest delivery attempt identity is invalid"
      end

      def validate_identity!(receipt, record_id:, destination_chat_id:)
        expected_record = normalize_digest(record_id, "record id")
        expected_chat = normalize_chat_id(destination_chat_id)
        return if receipt.fetch("record_id") == expected_record &&
                  receipt.fetch("destination_chat_id") == expected_chat

        raise Conflict, "digest delivery identity changed for #{receipt.fetch('local_date')}"
      end

      def sender_alive?(receipt)
        process_owner_alive?(receipt, "sender")
      end

      def prepared_owned?(receipt)
        receipt["preparer_id"] == preparer_id
      end

      def preparer_alive?(receipt)
        process_owner_alive?(receipt, "preparer")
      end

      def process_owner_alive?(receipt, role)
        pid = receipt["#{role}_pid"]
        return false unless pid.is_a?(Integer) && pid.positive?

        @process_alive.call(pid, receipt["#{role}_process_start_time"])
      rescue StandardError
        false
      end

      def preparer_fields
        pid, process_start_time = @process_identity.call
        {
          "preparer_id" => preparer_id,
          "preparer_pid" => pid.is_a?(Integer) && pid.positive? ? pid : nil,
          "preparer_process_start_time" => process_start_time&.to_s
        }
      rescue StandardError
        {
          "preparer_id" => preparer_id,
          "preparer_pid" => nil,
          "preparer_process_start_time" => nil
        }
      end

      def preparer_id
        fiber = Fiber.current
        identity = @preparer_ids[fiber]
        return identity.fetch(:id) if identity&.fetch(:pid) == Process.pid

        @preparer_ids[fiber] = { pid: Process.pid, id: SecureRandom.hex(16) }
        @preparer_ids[fiber].fetch(:id)
      end

      def matching_process_alive?(pid, recorded_start)
        return false unless Hive::ProcessKill.pid_alive?(pid)
        return false if recorded_start.to_s.empty?

        Hive::Lock.process_start_time(pid).to_s == recorded_start.to_s
      end

      def history_entry(attempt:, outcome:, at:, operator_retry: nil, reason_code: nil)
        {
          "attempt" => Integer(attempt), "outcome" => outcome, "at" => at,
          "operator_retry" => operator_retry, "reason_code" => bounded_reason(reason_code)
        }.compact
      end

      def bounded_reason(value)
        return nil if value.nil?

        value.to_s.gsub(/[\x00-\x1f\x7f]/, "").byteslice(0, 80)
      end

      def synchronize(shared: false)
        ensure_private_root!
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(File.join(root, ".ledger.lock"), flags, 0o600) do |lock|
          raise Error, "digest delivery lock is not a regular file" unless lock.stat.file?

          lock.chmod(0o600)
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise Error, "digest delivery lock cannot be a symlink"
      end

      def read_unlocked(date)
        path = receipt_path(date)
        return nil unless File.file?(path)

        parsed = JSON.parse(File.binread(path))
        unless parsed.is_a?(Hash) && parsed["schema"] == "hive-digest-delivery-receipt" &&
               parsed["schema_version"] == 1 && OUTCOMES.include?(parsed["outcome"])
          raise Error, "digest delivery receipt for #{date} is invalid"
        end
        parsed
      rescue JSON::ParserError => error
        raise Error, "digest delivery receipt for #{date} is corrupt: #{error.message}"
      end

      def write_unlocked(date, receipt)
        payload = Record.canonical_object(receipt)
        payload["receipt_id"] = Record.content_id(payload.reject { |key, _| key == "receipt_id" })
        Hive::AtomicFile.write(
          receipt_path(date), "#{Record.canonical_json(payload)}\n", mode: 0o600
        )
        File.chmod(0o600, receipt_path(date))
        Hive::AtomicFile.fsync_directory(root)
        payload
      end

      def ensure_private_root!
        FileUtils.mkdir_p(root, mode: 0o700)
        File.chmod(0o700, root)
      end

      def receipt_path(date)
        File.join(root, "#{normalize_date(date)}.json")
      end

      def receipt_dates
        Dir.children(root).filter_map do |name|
          match = /\A(\d{4}-\d{2}-\d{2})\.json\z/.match(name)
          match[1] if match
        end.sort
      end

      def normalize_date(value)
        Date.iso8601(value.to_s).iso8601
      rescue Date::Error, TypeError
        raise Error, "invalid digest delivery date #{value.inspect}"
      end

      def normalize_time(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise Error, "invalid digest delivery timestamp #{value.inspect}"
      end

      def normalize_digest(value, label)
        text = value.to_s
        raise Error, "digest delivery #{label} is invalid" unless text.match?(/\A[0-9a-f]{64}\z/)

        text
      end

      def normalize_chat_id(value)
        chat_id = Integer(value)
        raise ArgumentError if chat_id.zero?

        chat_id
      rescue ArgumentError, TypeError
        raise Error, "digest delivery requires a non-zero private chat id"
      end
    end
  end
end
