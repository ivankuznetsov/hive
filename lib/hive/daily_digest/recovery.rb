require "hive/daily_digest/coordinator"
require "hive/daily_digest/reader"

module Hive
  module DailyDigest
    # Explicit unresolved-gap retry. Coordinator remains the only writer; this
    # service merely decides whether a historical refresh is warranted and
    # reports which exact stable gaps were resolved by its amendment.
    class Recovery
      def initialize(reader: Reader.new, coordinator: Coordinator.new)
        @reader = reader
        @coordinator = coordinator
      end

      def call(date:, source: nil)
        before = @reader.read(date: date)
        unless before["reader_status"].nil? || before["reader_status"] == "ok"
          raise DailyDigest::Error, "digest #{date} is #{before.fetch('reader_status')}"
        end
        unless before.fetch("lifecycle") == "closed"
          raise DailyDigest::Error, "digest #{date} must be closed before source recovery"
        end
        gaps = Array(before["effective_gaps"] || before["gaps"])
        selected = source ? gaps.select { |gap| gap["source"] == source.to_s } : gaps
        if selected.empty?
          return {
            "local_date" => date.to_s, "status" => "nothing_to_retry",
            "attempted_gap_ids" => [], "resolved_gap_ids" => []
          }
        end

        @coordinator.refresh(date: date)
        after = @reader.read(date: date)
        remaining = Array(after["effective_gaps"] || after["gaps"])
                    .to_h { |gap| [ gap.fetch("gap_id"), true ] }
        attempted = selected.map { |gap| gap.fetch("gap_id") }.sort
        {
          "local_date" => date.to_s,
          "status" => "retried",
          "attempted_gap_ids" => attempted,
          "resolved_gap_ids" => attempted.reject { |gap_id| remaining[gap_id] }
        }
      end
    end
  end
end
