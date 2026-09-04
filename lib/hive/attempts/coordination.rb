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

      def attempt_id_for_request(request_id:)
        row = database.read do |db|
          db[:attempts].where(request_id: identifier(request_id))
            .reverse_order(:accepted_at, :lease_version, :attempt_id).first
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
            .where(
              Sequel.|(
                { lost_recovery_phase: nil },
                { lost_recovery_phase: %w[pending ready] }
              )
            )
            .reverse_order(:ended_at, :lease_version, :attempt_id).first
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
        acceptance_for!(record)
        database.transaction do |db|
          db[:attempts].where(
            attempt_id: record.attempt_id, accepted_at: record["accepted_at"],
            project_name: record["project"], refunded: 0
          ).update(refunded: 1)
        end
        record
      end

      def admission_metadata(attempt_id)
        row = database.read do |db|
          db[:attempts].where(attempt_id: identifier(attempt_id)).first
        end
        row && admission_from(row)
      end

      def record_failure_cohort(attempt_id:, identity:, occurred_at:)
        normalized = failure_cohort_identity(identity)
        attempt = identifier(attempt_id)
        occurred = time_value(occurred_at)
        date = occurred.utc.to_date.iso8601
        digest = failure_cohort_digest(normalized)
        database.transaction do |db|
          attempt_row = db[:attempts].where(attempt_id: attempt).first
          unless attempt_row && %w[terminal lost].include?(attempt_row.fetch(:state))
            raise RepositoryError, "failure cohort attempt is not final"
          end
          existing = failure_fact(attempt_row)
          expected = {
            outcome: "failed", date: date, identity_digest: digest,
            occurred_at: Record.iso8601(occurred), counted: 1
          }
          if existing
            unless existing == expected
              raise RepositoryError, "failure cohort attempt fact conflicts"
            end
            next
          end

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
          changed = db[:attempts].where(
            attempt_id: attempt, failure_cohort_outcome: nil,
            failure_cohort_counted: 0
          ).update(
            failure_cohort_date: date, failure_cohort_identity_digest: digest,
            failure_cohort_outcome: "failed",
            failure_cohort_occurred_at: Record.iso8601(occurred),
            failure_cohort_counted: 1
          )
          raise RepositoryError, "failure cohort attempt fact changed concurrently" unless changed == 1
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
          attempt_row = db[:attempts].where(attempt_id: attempt).first
          unless attempt_row && attempt_row.fetch(:state) == "terminal" &&
                 attempt_row.fetch(:outcome) == "succeeded"
            raise RepositoryError, "failure cohort success requires a successful terminal attempt"
          end
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
            occurred_at = attempt_row.fetch(:ended_at)
            changed = db[:attempts].where(
              attempt_id: attempt, failure_cohort_outcome: nil,
              failure_cohort_counted: 0
            ).update(
              failure_cohort_date: utc_date, failure_cohort_identity_digest: nil,
              failure_cohort_outcome: "succeeded", failure_cohort_occurred_at: occurred_at,
              failure_cohort_counted: 0
            )
            raise RepositoryError, "failure cohort attempt fact changed concurrently" unless changed == 1
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
        row = database.read do |db|
          db[:attempts].where(
            attempt_id: record.attempt_id, accepted_at: record["accepted_at"],
            project_name: record["project"], retry_charge: record["retry_charge"]
          ).first
        end
        raise RepositoryError, "daily accounting acceptance is missing" unless row
        row
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

      def admission_from(row)
        return nil unless row[:admission_workflow]

        live_admission(
          "workflow" => row.fetch(:admission_workflow),
          "stage" => row.fetch(:admission_stage),
          "runtime_digest" => row.fetch(:admission_runtime_digest),
          "utc_date" => row.fetch(:admission_utc_date)
        )
      end

      def failure_fact(row)
        return nil unless row[:failure_cohort_outcome]

        {
          outcome: row.fetch(:failure_cohort_outcome),
          date: row.fetch(:failure_cohort_date),
          identity_digest: row[:failure_cohort_identity_digest],
          occurred_at: row.fetch(:failure_cohort_occurred_at),
          counted: row.fetch(:failure_cohort_counted)
        }
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
