require "json"
require "time"
require "hive/daemon/patrol_fix_runtime"
require "hive/errors"
require "hive/patrol_fix/admission_store"
require "hive/secret_patterns"

module Hive
  module Commands
    # Hidden ChildSupervisor verb for exactly one reserved semantic admission.
    # AdmissionStore is authoritative; stdout is only the bounded completion
    # envelope consumed by the existing child protocol.
    class PatrolFixSemanticDecision
      def initialize(project, source:, occurrence_id:, reservation_id:,
                     runtime: Hive::Daemon::PatrolFixRuntime.new,
                     clock: -> { Time.now.utc })
        @project = bounded_identity(project, "project", 128)
        @source = source.to_s
        unless Hive::PatrolFix::SourceSnapshot::ENGINES.include?(@source)
          raise Hive::ConfigError, "Patrol Fix semantic source is invalid"
        end
        @occurrence_id = bounded_identity(occurrence_id, "occurrence", 128)
        @reservation_id = reservation_id.to_s
        unless @reservation_id.match?(Hive::PatrolFix::AdmissionStore::DIGEST)
          raise Hive::ConfigError, "Patrol Fix semantic reservation is invalid"
        end
        @runtime = runtime
        @clock = clock
      end

      def call
        record = @runtime.run_semantic_decision(
          project: @project, source_name: @source,
          occurrence_id: @occurrence_id, reservation_id: @reservation_id,
          now: @clock.call
        )
        emit(
          "schema" => "hive-patrol-fix-semantic-decision-result",
          "schema_version" => 1, "ok" => true,
          "occurrence_id" => @occurrence_id, "status" => record.fetch("status")
        )
        Hive::ExitCodes::SUCCESS
      rescue StandardError => error
        retry_at = error.respond_to?(:retry_at) ? error.retry_at : nil
        emit(
          "schema" => "hive-patrol-fix-semantic-decision-result",
          "schema_version" => 1, "ok" => false,
          "occurrence_id" => @occurrence_id,
          "error_class" => error.class.name.to_s,
          "error" => Hive::SecretPatterns.redact(error.message.to_s)[0, 512],
          "retry_at" => normalize_retry_at(retry_at)
        )
        Hive::ExitCodes::TEMPFAIL
      end

      private

      def bounded_identity(value, label, max)
        text = value.to_s
        unless !text.empty? && text.bytesize <= max &&
               !text.match?(/[\u0000-\u001f\u007f]/)
          raise Hive::ConfigError, "Patrol Fix semantic #{label} is invalid"
        end
        text
      end

      def normalize_retry_at(value)
        return nil if value.nil?

        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601
      rescue ArgumentError
        nil
      end

      def emit(payload)
        puts JSON.generate(payload)
        payload
      end
    end
  end
end
