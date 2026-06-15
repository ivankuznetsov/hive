require "date"
require "json"
require "hive/digest"

module Hive
  module Commands
    class Digest
      def initialize(date: nil, dry_run: false, json: false, runner: Hive::Digest, output: $stdout)
        @date = date
        @dry_run = dry_run
        @json = json
        @runner = runner
        @output = output
      end

      def call
        local_date = parse_date
        result = @runner.run(date: local_date, dry_run: @dry_run)
        emit(result)
        result
      rescue Hive::Error => e
        # A bad --date raises Hive::ConfigError, which Thor never sees (it is
        # not a Thor::Error), so bin/hive's JSON_USAGE_ERROR_CONTRACTS path
        # never fires for it. Emit the in-command JSON error envelope here —
        # mirroring ~10 sibling commands — before re-raising, so an agent
        # parsing --json stdout gets a structured error on the most common
        # usage mistake. Non-JSON output and the exit code are unchanged.
        emit_error_envelope(e) if @json
        raise
      end

      private

      def parse_date
        # No --date: defer to Hive::Digest.run, which owns the single
        # "local day that just ended" default (and its injectable clock).
        # Computing it here too would duplicate that default across two
        # sites that could drift.
        return nil if @date.to_s.empty?

        unless @date.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
        end

        Hive::Digest::Window.parse_date(@date)
      rescue ArgumentError
        raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
      end

      def emit(result)
        if @json
          @output.puts JSON.generate(json_payload(result))
        elsif @dry_run
          @output.puts result.message
        else
          @output.puts "hive digest: #{result.status} for #{result.date.iso8601}"
        end
      end

      def json_payload(result)
        {
          # Derive from status so a machine consumer can tell a delivered
          # digest from one that fell back to a failure notice.
          "ok" => result.status != :failed_notice,
          "schema" => "hive-digest",
          # Versioned like every other --json envelope; fetched from the
          # single SCHEMA_VERSIONS registry so the two can't drift.
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-digest"),
          "date" => result.date.iso8601,
          "status" => result.status.to_s,
          "dry_run" => @dry_run,
          # The recipient the send actually resolved (nil on a dry-run, which
          # resolves none) — surfaced for post-send auditability. Optional in
          # the schema, so older consumers that ignore it stay compatible.
          "chat_id" => result.delivery&.chat_id,
          "message" => @dry_run ? result.message : nil
        }
      end

      def emit_error_envelope(error)
        @output.puts JSON.generate(
          "schema" => "hive-digest",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-digest"),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "internal",
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        )
      end
    end
  end
end
