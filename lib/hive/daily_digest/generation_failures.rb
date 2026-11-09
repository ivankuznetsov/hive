require "json"
require "time"
require "hive/atomic_file"
require "hive/secret_patterns"

module Hive
  module DailyDigest
    # The latest failed document generation per local date. Records are
    # immutable, so a failed refresh writes nothing there; without this ledger
    # readers kept serving the previous day as if it were current. A
    # successful write for the same date clears its entry.
    class GenerationFailures
      FILE = "generation-failures.json".freeze
      MESSAGE_LIMIT = 2_000

      def initialize(root:, clock: -> { Time.now.utc })
        @path = File.join(root, FILE)
        @clock = clock
      end

      def record(date, error)
        entries = all
        entries[date] = {
          "local_date" => date,
          "failed_at" => @clock.call.utc.iso8601(6),
          "error_class" => error.class.name,
          "message" => Hive::SecretPatterns.redact(error.message.to_s)[0, MESSAGE_LIMIT]
        }
        write(entries)
      end

      def clear(date)
        entries = all
        write(entries) if entries.delete(date)
      end

      def for(date)
        all[date]
      end

      # The newest failure for a date after +date+, used when an implicit
      # "today" read falls back to an older saved document.
      def newer_than(date)
        all.values.select { |entry| date.nil? || entry.fetch("local_date") > date }
           .max_by { |entry| entry.fetch("local_date") }
      end

      def all
        return {} unless File.file?(@path)

        value = JSON.parse(File.read(@path))
        value.is_a?(Hash) ? value.select { |_, entry| entry.is_a?(Hash) && entry["local_date"].is_a?(String) } : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      private

      def write(entries)
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        AtomicFile.write(@path, JSON.pretty_generate(entries.sort.to_h), mode: 0o600)
      end
    end
  end
end
