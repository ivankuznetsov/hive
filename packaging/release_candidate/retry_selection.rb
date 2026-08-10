# frozen_string_literal: true

require_relative "paths"

module HiveReleaseCandidate
  class RetrySelection
    def initialize(required_names:)
      @required_names = required_names.freeze
    end

    def call(source:, selector:)
      raise Error, "retry source evidence is invalid" unless source.is_a?(Hash)
      raise Error, "retry selector is invalid" unless selector.is_a?(Hash)

      rows = Array(source["effective_gate_set"])
      names = case selector["mode"]
      when "named"
                Array(selector["gates"]).map(&:to_s)
      when "failed"
                rows.filter_map do |row|
                  next unless row.is_a?(Hash)
                  next if row["status"] == "completed" && row["conclusion"] == "success"

                  row["name"].to_s
                end
      when "missing"
                @required_names - rows.filter_map do |row|
                  row["name"].to_s if row.is_a?(Hash)
                end
      else
                raise Error, "retry selector mode is invalid"
      end

      unless !names.empty? && names.uniq.size == names.size &&
             (names - @required_names).empty?
        raise Error, "retry selector does not resolve one exact eligible gate set"
      end

      names.sort
    end
  end
end
