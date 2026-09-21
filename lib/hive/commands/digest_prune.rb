require "json"
require "hive/daily_digest/pruner"

module Hive
  module Commands
    # Explicit digest-projection retention boundary. Underlying task, attempt,
    # PR, delivery, and audit evidence is outside the pruner's store contract.
    class DigestPrune
      SCHEMA = "hive-digest-prune".freeze

      def initialize(before:, dry_run: false, confirm: false, json: false,
                     pruner: DailyDigest::Pruner.new, stdout: $stdout)
        @before = before
        @dry_run = dry_run
        @confirm = confirm
        @json = json
        @pruner = pruner
        @stdout = stdout
      end

      def call!
        validate_options!
        result = @pruner.call(before: @before, dry_run: @dry_run, confirm: @confirm)
        payload = {
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          **result
        }
        if @json
          @stdout.puts(JSON.generate(payload))
        else
          verb = @dry_run ? "would prune" : "pruned"
          dates = Array(result[@dry_run ? "eligible" : "pruned"])
          @stdout.puts("Digest projection #{verb} #{dates.length} day(s).")
          dates.each { |date| @stdout.puts("- #{date}") }
        end
        @emitted = true if @json
        payload
      rescue Hive::Error => error
        emit_error(error) if @json && !@emitted
        raise
      rescue StandardError => error
        wrapped = Hive::InternalError.new(
          "hive digest prune failed: #{error.class}: #{error.message}"
        )
        emit_error(wrapped) if @json && !@emitted
        raise wrapped
      end

      alias call call!

      private

      def validate_options!
        raise Hive::UsageError, "digest prune requires --before DATE" if @before.to_s.empty?
        if @dry_run && @confirm
          raise Hive::UsageError, "digest prune accepts either --dry-run or --yes, not both"
        end
        return if @dry_run || @confirm

        raise Hive::UsageError, "digest prune requires --dry-run or --yes"
      end

      def emit_error(error)
        @stdout.puts(
          JSON.generate(
            Hive::Schemas::ErrorEnvelope.build(
              schema: SCHEMA, error: error, error_kind: error_kind(error)
            )
          )
        )
        @emitted = true
      rescue Errno::EPIPE
        @emitted = true
      end

      def error_kind(error)
        case error
        when Hive::UsageError then "usage"
        when DailyDigest::Pruner::ConfirmationRequired then "confirmation_required"
        when DailyDigest::InvalidRecord then "invalid_date"
        when DailyDigest::MissingRecord then "missing"
        when DailyDigest::Store::ImmutableRecord then "immutable"
        when Hive::ConfigError then "config"
        when Hive::InternalError then "internal"
        else "digest_error"
        end
      end
    end
  end
end
