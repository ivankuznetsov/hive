require "date"
require "time"
require "hive/daily_digest/store"

module Hive
  module DailyDigest
    # Explicit projection-only retention action. The default is a dry run;
    # callers must pass confirm:true before any base or amendment is removed.
    class Pruner
      class ConfirmationRequired < DailyDigest::Error; end

      def initialize(store: Store.new, clock: -> { Time.now.utc })
        @store = store
        @clock = clock
      end

      def call(before:, dry_run: false, confirm: false)
        cutoff = Date.iso8601(before.to_s)
        eligible = @store.dates.select do |date|
          next false unless Date.iso8601(date) < cutoff

          record = @store.read(date)
          record["lifecycle"] == "closed" &&
            Time.iso8601(record.fetch("ends_at")) <= utc(@clock.call)
        rescue DailyDigest::MissingRecord
          false
        end.sort
        return envelope(cutoff, eligible: eligible, pruned: [], dry_run: true) if dry_run
        raise ConfirmationRequired, "digest prune requires explicit confirmation" unless confirm

        pruned = eligible.map do |date|
          @store.prune(date, pruned_at: @clock.call, reason: "operator_confirmed")
          date
        end
        envelope(cutoff, eligible: eligible, pruned: pruned, dry_run: false)
      rescue Date::Error, TypeError
        raise DailyDigest::InvalidRecord, "invalid digest prune date #{before.inspect}"
      end

      private

      def envelope(cutoff, eligible:, pruned:, dry_run:)
        {
          "before" => cutoff.iso8601, "dry_run" => dry_run,
          "eligible" => eligible, "pruned" => pruned
        }
      end

      def utc(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      end
    end
  end
end
