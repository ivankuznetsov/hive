require "json"
require "time"

module Hive
  module OneShot
    module Readiness
      BUCKETS = %w[runnable_now waiting_external waiting_operator].freeze

      module_function

      def project(items:, finished_at:)
        finished_at = time(finished_at)
        pending = BUCKETS.to_h { |bucket| [ bucket, [] ] }
        ids = {}

        Array(items).each do |raw|
          item = stringify(raw)
          bucket = item.delete("bucket").to_s
          raise ArgumentError, "unknown one-shot readiness bucket #{bucket.inspect}" unless BUCKETS.include?(bucket)

          id = item.fetch("id").to_s
          raise ArgumentError, "duplicate one-shot pending id #{id.inspect}" if ids[id]

          ids[id] = true
          item["id"] = id
          item["component"] = item.fetch("component").to_s
          item["reason"] = item.fetch("reason").to_s
          item["next_check_at"] = timestamp(item["next_check_at"])
          item["condition"] = stringify(item["condition"]) if item["condition"]
          pending.fetch(bucket) << item
        end

        {
          "pending" => pending,
          "next_due_at" => next_due_at(pending, finished_at),
          "wake_conditions" => wake_conditions(pending.fetch("waiting_external"))
        }
      end

      def timestamp(value)
        value && time(value).utc.iso8601(6)
      end

      def time(value)
        return value if value.is_a?(Time)

        Time.iso8601(value.to_s)
      rescue ArgumentError
        raise ArgumentError, "invalid one-shot timestamp #{value.inspect}"
      end

      def next_due_at(pending, finished_at)
        return timestamp(finished_at) if pending.fetch("runnable_now").any?

        deadlines = pending.fetch("waiting_external").filter_map do |item|
          time(item["next_check_at"]) if item["next_check_at"]
        end
        return nil if deadlines.empty?

        timestamp([ deadlines.min, finished_at ].max)
      end

      def wake_conditions(items)
        group_by_condition(items)
      end

      def group_by_condition(items, id_prefix: nil)
        grouped = {}
        items.each do |item|
          condition = item["condition"] || item.reject do |key, _value|
            key == "affected_pending_ids"
          end
          next unless condition

          key = JSON.generate(condition.sort.to_h)
          grouped[key] ||= condition.merge("affected_pending_ids" => [])
          ids = item.key?("affected_pending_ids") ?
            Array(item.fetch("affected_pending_ids")) : [ item.fetch("id") ]
          ids.each do |id|
            grouped[key]["affected_pending_ids"] <<
              (id_prefix ? "#{id_prefix}:#{id}" : id)
          end
        end
        grouped.values.each do |condition|
          condition["affected_pending_ids"].uniq!
          condition["affected_pending_ids"].sort!
        end
      end

      def stringify(value)
        return value.transform_keys(&:to_s) if value.is_a?(Hash)

        value
      end
    end
  end
end
