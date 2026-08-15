require "json"
require "time"

module Hive
  module TaskWorkspace
    class Field
      attr_reader :value, :state, :source, :evidence_ref, :observed_at,
                  :quality, :conflicts, :truncated

      def self.resolve(candidates, precedence: TaskWorkspace::SOURCE_PRECEDENCE)
        normalized = Array(candidates).map do |candidate|
          candidate.to_h.transform_keys(&:to_s)
        end
        raise ArgumentError, "field candidates must not be empty" if normalized.empty?

        ordered = normalized.sort_by.with_index do |candidate, index|
          [ precedence.fetch(candidate.fetch("source").to_s, precedence.length), index ]
        end
        selected = ordered.first
        values = ordered.map { |candidate| TaskWorkspace.canonical_json(candidate["value"]) }.uniq
        state = values.one? ? selected.fetch("state", "current") : "conflicting"
        new(
          value: selected["value"], state: state, source: selected.fetch("source"),
          evidence_ref: selected["evidence_ref"], observed_at: selected["observed_at"],
          quality: selected["quality"], conflicts: values.one? ? [] : ordered,
          truncated: ordered.any? { |candidate| candidate["truncated"] == true }
        )
      end

      def initialize(value:, state:, source:, evidence_ref: nil, observed_at: nil,
                     quality: nil, conflicts: [], truncated: false)
        @state = state.to_s
        @source = source.to_s
        raise ArgumentError, "invalid workspace field state #{@state.inspect}" unless
          TaskWorkspace::STATES.include?(@state)
        raise ArgumentError, "invalid workspace source #{@source.inspect}" unless
          TaskWorkspace::SOURCES.include?(@source)

        @evidence_ref = normalize_reference(evidence_ref)
        @observed_at = normalize_time(observed_at)
        @quality = quality&.to_s
        @value = TaskWorkspace.safe_value!(value)
        @conflicts = Array(conflicts).map do |candidate|
          TaskWorkspace.safe_value!(candidate.to_h.transform_keys(&:to_s))
        end.freeze
        @truncated = truncated == true
      end

      def to_h
        {
          "value" => value,
          "state" => state,
          "source" => source,
          "evidence_ref" => evidence_ref,
          "observed_at" => observed_at,
          "quality" => quality,
          "conflicts" => conflicts,
          "truncated" => truncated
        }
      end

      private

      def normalize_reference(reference)
        return nil if reference.nil?

        value = reference.to_s
        if value.empty? || value.start_with?("/", "\\") ||
           value.match?(/\A[A-Za-z]:[\\\/]/) ||
           value.split(/[\\\/]/).include?("..") || value.include?("\0")
          raise ArgumentError, "workspace evidence reference must be task-relative"
        end
        raise ArgumentError, "workspace evidence reference is too large" if value.bytesize > 1_024

        value
      end

      def normalize_time(value)
        return nil if value.nil?

        Time.iso8601(value.to_s).utc.iso8601(6)
      rescue ArgumentError
        raise ArgumentError, "invalid workspace observation timestamp"
      end
    end
  end
end
