require "hive/agent_limit"
require "time"
require "hive/attempts/record"
require "hive/runtime_control_plane"

module Hive
  module Attempts
    # Transactional queries and accounting owned by the Attempts domain.
    # Historical lookup uses the same attempt rows as live execution.
    module Coordination
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

      # Retry pacing is a read of this task's latest final attempt, not a
      # project-wide failure counter or a persisted provider circuit.
      def patrol_retry_at(task_generation:, subject:, runtime_digest:, now:)
        row = database.read do |db|
          semantic_attempts(db, task_generation, subject).where(state: %w[terminal lost])
            .reverse_order(:ended_at, :lease_version, :attempt_id).first
        end
        return nil unless row && row[:admission_workflow] == "patrol_fix" &&
                          row[:admission_runtime_digest] == runtime_digest
        return nil unless row[:state] == "lost" || %w[failed cancelled].include?(row[:outcome])

        retry_at = Time.iso8601(row.fetch(:ended_at)) + Hive::AgentLimit.retry_cooldown_sec
        retry_at if now < retry_at
      end

      private

      def terminal_for(task_generation, subject, outcome: nil)
        database.read do |db|
          dataset = semantic_attempts(db, task_generation, subject).where(state: "terminal")
          dataset = dataset.where(outcome: outcome) if outcome
          dataset.reverse_order(:ended_at, :lease_version, :attempt_id).first
        end
      end

      def semantic_attempts(db, task_generation, subject)
        subject = RuntimeControlPlane::Codec.normalize(subject)
        db[:attempts].where(
          task_id: subject["task_id"],
          task_generation: identifier(task_generation),
          subject_key: digest(subject)
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
        unless value.keys.sort == %w[runtime_digest workflow] &&
               value["workflow"] == "patrol_fix" &&
               Record::SHA256_PATTERN.match?(value["runtime_digest"].to_s)
          raise RepositoryError, "live capacity admission metadata is invalid"
        end
        value
      rescue ArgumentError, KeyError, TypeError, RuntimeControlPlane::Error
        raise RepositoryError, "live capacity admission metadata is invalid"
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
