require "date"
require "digest"
require "time"
require "hive/attempts/record"
require "hive/runtime_control_plane"

module Hive
  module Attempts
    # Transactional queries and accounting owned by the Attempts domain.
    # Historical lookup is now an indexed query over attempts, not a second
    # set of transactional rows rather than repairable point-addressed files.
    module Coordination
      MAX_FAILURE_COHORTS = 512
      FAILURE_COHORT_THRESHOLD = 3
      FAILURE_COHORT_COOLDOWN_SEC = 60 * 60
      FAILURE_COHORT_PROBE_TTL_SEC = 24 * 60 * 60

      def terminal_attempt_id(request_id:)
        row = database.read do |db|
          db[:attempts].where(request_id: identifier(request_id), state: "terminal")
                       .reverse_order(:ended_at, :lease_version, :attempt_id).first
        end
        row && row.fetch(:attempt_id)
      end

      def latest_terminal_attempt_id(task_generation:, subject:)
        terminal_for(task_generation, subject)&.fetch(:attempt_id)
      end

      def successful_attempt_id(task_generation:, subject:)
        terminal_for(task_generation, subject, outcome: "succeeded")&.fetch(:attempt_id)
      end

      def unresolved_loss_attempt_id(task_generation:, subject:)
        row = database.read do |db|
          semantic_attempts(db, task_generation, subject).where(state: "lost")
            .reverse_order(:ended_at, :lease_version, :attempt_id).first
        end
        return nil unless row
        return nil if successor_attempt_id(predecessor_attempt_id: row.fetch(:attempt_id))

        row.fetch(:attempt_id)
      end

      def successor_attempt_id(predecessor_attempt_id:)
        row = database.read do |db|
          db[:attempt_relationships].where(
            related_attempt_id: identifier(predecessor_attempt_id), kind: "successor"
          ).first
        end
        row && row.fetch(:attempt_id)
      end

      def refund_unstarted(record)
        unless record.state == "lost" && record["started_at"].nil?
          raise RepositoryError, "daily accounting unstarted refund requires a lost attempt that never ran"
        end
        mark_refunded(record)
      end

      def refund_tempfail(record)
        terminal!(record)
        unless record.receipt["exit_status"] == Hive::ExitCodes::TEMPFAIL
          raise RepositoryError, "daily accounting refund requires a TEMPFAIL receipt"
        end
        mark_refunded(record)
      end

      def mark_refunded(record)
        row = acceptance_for!(record)
        billing = RuntimeControlPlane::Codec.load_json(row.fetch(:billing_json))
        update_accounting(
          record.attempt_id,
          refunded: 1, billing_json: RuntimeControlPlane::Codec.dump_json(billing.merge("refunded" => true))
        )
        record
      end

      def reservation_metadata(attempt_id)
        row = database.read do |db|
          db[:attempt_accounting].where(attempt_id: identifier(attempt_id)).first
        end
        row && RuntimeControlPlane::Codec.load_json(row.fetch(:reservation_json))
      end

      def release_live(attempt_id:)
        id = identifier(attempt_id)
        database.transaction do |db|
          db[:capacity_reservations].where(attempt_id: id, state: "reserved")
                                    .update(state: "released", released_at: Record.iso8601(Time.now.utc))
        end
        true
      end

      def record_failure_cohort(attempt_id:, identity:, occurred_at:)
        normalized = failure_cohort_identity(identity)
        attempt = identifier(attempt_id)
        occurred = time_value(occurred_at)
        date = occurred.utc.to_date.iso8601
        digest = failure_cohort_digest(normalized)
        database.transaction do |db|
          events = db[:attempt_failure_events]
          next if events.where(utc_date: date, attempt_id: attempt).any?

          # A probe that returns a different code still closes its original
          # probe fence before the new cohort is counted.
          db[:attempt_failure_cohorts].where(utc_date: date, probe_attempt_id: attempt).all.each do |row|
            update_cohort_after_failure(db, row, occurred, clear_probe: true)
          end
          row = db[:attempt_failure_cohorts].where(
            utc_date: date, identity_digest: digest
          ).first
          row ||= insert_empty_cohort(db, date, digest, normalized, occurred)
          update_cohort_after_failure(
            db, row, occurred, clear_probe: row[:probe_attempt_id] == attempt,
            increment: true
          )
          events.insert(
            utc_date: date, attempt_id: attempt, identity_digest: digest,
            outcome: "failed", occurred_at: Record.iso8601(occurred)
          )
        end
        true
      rescue Sequel::Error => error
        raise RepositoryError, "failure cohort could not be recorded: #{error.message}"
      end

      def record_failure_cohort_success(attempt_id:, date:)
        attempt = identifier(attempt_id)
        utc_date = date_value(date).iso8601
        found = false
        database.transaction do |db|
          rows = db[:attempt_failure_cohorts].where(
            utc_date: utc_date, probe_attempt_id: attempt
          ).all
          found = !rows.empty?
          rows.each do |row|
            db[:attempt_failure_cohorts].where(
              utc_date: utc_date, identity_digest: row.fetch(:identity_digest)
            ).delete
          end
          if found
            db[:attempt_failure_events].insert_conflict.insert(
              utc_date: utc_date, attempt_id: attempt, outcome: "succeeded",
              occurred_at: Record.iso8601(Time.now.utc)
            )
          end
        end
        found
      end

      def failure_cohort_admission(identity:, date:, now:, explicit_release: false)
        normalized = failure_cohort_identity(identity)
        current_time = time_value(now)
        row = cohort_row(normalized, date)
        return open_cohort unless row && row.fetch(:failure_count) >= FAILURE_COHORT_THRESHOLD

        row = expire_probe(row, current_time)
        return blocked_cohort if row[:probe_attempt_id]
        return probe_cohort if explicit_release || current_time >= Time.iso8601(row.fetch(:retry_at))

        blocked_cohort(retry_at: row.fetch(:retry_at))
      end

      def claim_failure_cohort_probe(identity:, date:, attempt_id:, now:, explicit_release: false)
        database.transaction do |db|
          claim_failure_cohort_probe_in(
            db, identity: identity, date: date, attempt_id: attempt_id,
            now: now, explicit_release: explicit_release
          )
        end
      end

      def release_failure_cohort_probe(identity:, date:, attempt_id:)
        normalized = failure_cohort_identity(identity)
        updated = database.transaction do |db|
          db[:attempt_failure_cohorts].where(
            utc_date: date_value(date).iso8601,
            identity_digest: failure_cohort_digest(normalized),
            probe_attempt_id: identifier(attempt_id)
          ).update(probe_attempt_id: nil, probe_expires_at: nil)
        end
        updated == 1
      end

      private

      def claim_failure_cohort_probe_in(db, identity:, date:, attempt_id:, now:,
                                        explicit_release: false)
        normalized = failure_cohort_identity(identity)
        utc_date = date_value(date).iso8601
        current_time = time_value(now)
        digest = failure_cohort_digest(normalized)
        row = db[:attempt_failure_cohorts].where(
          utc_date: utc_date, identity_digest: digest
        ).first
        return false unless row && row.fetch(:failure_count) >= FAILURE_COHORT_THRESHOLD

        row = expire_probe(row, current_time, db: db)
        return false if row[:probe_attempt_id]
        return false unless explicit_release || current_time >= Time.iso8601(row.fetch(:retry_at))

        db[:attempt_failure_cohorts].where(
          utc_date: utc_date, identity_digest: digest, probe_attempt_id: nil
        ).update(
          probe_attempt_id: identifier(attempt_id),
          probe_expires_at: Record.iso8601(current_time + FAILURE_COHORT_PROBE_TTL_SEC),
          updated_at: Record.iso8601(current_time)
        ) == 1
      end

      def terminal_for(task_generation, subject, outcome: nil)
        database.read do |db|
          dataset = semantic_attempts(db, task_generation, subject).where(state: "terminal")
          dataset = dataset.where(outcome: outcome) if outcome
          dataset.reverse_order(:ended_at, :lease_version, :attempt_id).first
        end
      end

      def semantic_attempts(db, task_generation, subject)
        db[:attempts].where(
          task_generation: identifier(task_generation),
          subject_json: RuntimeControlPlane::Codec.dump_json(subject)
        )
      end

      def acceptance_for!(record)
        row, accepted = database.read do |db|
          [
            db[:attempt_accounting].where(attempt_id: record.attempt_id).first,
            db[:attempts].where(
              attempt_id: record.attempt_id, accepted_at: record["accepted_at"],
              project_name: record["project"]
            ).any?
          ]
        end
        unless row && accepted
          raise RepositoryError, "daily accounting acceptance is missing"
        end
        row
      end

      def update_accounting(attempt_id, values)
        database.transaction do |db|
          db[:attempt_accounting].where(attempt_id: attempt_id).update(values)
        end
      end

      def live_reservation(project:, task_slug:, admission: nil, phase: "active")
        raise RepositoryError, "live capacity reservation phase is invalid" unless phase == "active"
        value = {
          "project" => identifier(project), "task_slug" => identifier(task_slug),
          "phase" => "active"
        }
        value["admission"] = live_admission(admission) if admission
        value
      end

      def live_admission(admission)
        value = RuntimeControlPlane::Codec.normalize(admission)
        unless value.keys.sort == %w[runtime_digest stage utc_date workflow] &&
               value["workflow"] == "patrol_fix" &&
               Record::SHA256_PATTERN.match?(value["runtime_digest"].to_s)
          raise RepositoryError, "live capacity admission metadata is invalid"
        end
        identifier(value["stage"])
        date_value(value["utc_date"])
        value
      rescue ArgumentError, KeyError, TypeError, RuntimeControlPlane::Error
        raise RepositoryError, "live capacity admission metadata is invalid"
      end

      def failure_cohort_identity(identity)
        value = RuntimeControlPlane::Codec.normalize(identity)
        unless value.keys.sort == %w[code project runtime_digest stage workflow]
          raise RepositoryError, "failure cohort identity is invalid"
        end
        %w[code project stage workflow].each { |key| identifier(value.fetch(key)) }
        unless Record::SHA256_PATTERN.match?(value.fetch("runtime_digest").to_s)
          raise RepositoryError, "failure cohort runtime digest is invalid"
        end
        value
      rescue ArgumentError, KeyError, TypeError, RuntimeControlPlane::Error
        raise RepositoryError, "failure cohort identity is invalid"
      end

      def failure_cohort_digest(identity) =
        Digest::SHA256.hexdigest(RuntimeControlPlane::Codec.dump_json(identity))

      def cohort_row(identity, date)
        database.read do |db|
          db[:attempt_failure_cohorts].where(
            utc_date: date_value(date).iso8601,
            identity_digest: failure_cohort_digest(identity)
          ).first
        end
      end

      def insert_empty_cohort(db, date, digest, identity, occurred)
        row = {
          utc_date: date, identity_digest: digest,
          identity_json: RuntimeControlPlane::Codec.dump_json(identity),
          failure_count: 0, retry_at: nil, probe_attempt_id: nil,
          probe_expires_at: nil, updated_at: Record.iso8601(occurred)
        }
        db[:attempt_failure_cohorts].insert(row)
        row
      end

      def update_cohort_after_failure(db, row, occurred, clear_probe:, increment: false)
        count = row.fetch(:failure_count) + (increment ? 1 : 0)
        retry_at = row[:retry_at] && Time.iso8601(row[:retry_at])
        if count >= FAILURE_COHORT_THRESHOLD
          retry_at = [ retry_at, occurred + FAILURE_COHORT_COOLDOWN_SEC ].compact.max
        end
        values = {
          failure_count: count,
          retry_at: retry_at && Record.iso8601(retry_at),
          updated_at: Record.iso8601(occurred)
        }
        values.merge!(probe_attempt_id: nil, probe_expires_at: nil) if clear_probe
        db[:attempt_failure_cohorts].where(
          utc_date: row.fetch(:utc_date), identity_digest: row.fetch(:identity_digest)
        ).update(values)
      end

      def expire_probe(row, now, db: nil)
        expiry = row[:probe_expires_at]
        return row unless expiry && Time.iso8601(expiry) <= now

        values = { probe_attempt_id: nil, probe_expires_at: nil, updated_at: Record.iso8601(now) }
        if db
          db[:attempt_failure_cohorts].where(
            utc_date: row.fetch(:utc_date), identity_digest: row.fetch(:identity_digest)
          ).update(values)
        else
          database.transaction do |database|
            database[:attempt_failure_cohorts].where(
              utc_date: row.fetch(:utc_date), identity_digest: row.fetch(:identity_digest)
            ).update(values)
          end
        end
        row.merge(values)
      end

      def open_cohort = { "status" => "open", "reason" => nil }.freeze
      def probe_cohort = { "status" => "probe", "reason" => nil }.freeze

      def blocked_cohort(retry_at: nil)
        {
          "status" => "blocked", "reason" => "failure_cohort_cooldown",
          "retry_at" => retry_at
        }.freeze
      end

      def semantic_key(generation, subject_json)
        Digest::SHA256.hexdigest([ generation, subject_json ].join("\0"))
      end

      def date_value(value)
        value.is_a?(Date) ? value : Date.iso8601(value.to_s)
      rescue Date::Error, ArgumentError
        raise RepositoryError, "daily accounting date is invalid"
      end

      def time_value(value)
        value.is_a?(Time) ? value.utc : Time.iso8601(value.to_s).utc
      rescue ArgumentError, TypeError
        raise RepositoryError, "failure cohort time is invalid"
      end

      def identifier(value)
        string = value.to_s
        unless string.bytesize.between?(1, Record::MAX_IDENTIFIER_BYTES) &&
               string.valid_encoding? && !string.match?(/[\u0000-\u001f\u007f]/)
          raise RepositoryError, "runtime identity is invalid"
        end
        string
      end


      def record!(record)
        return record if record.is_a?(Record)
        raise RepositoryError, "attempt decision query requires a schema-v4 record"
      end

      def terminal!(record)
        record!(record)
        return record if record.state == "terminal"
        raise RepositoryError, "terminal decision query requires a terminal schema-v4 record"
      end
    end
  end
end
