require "digest"
require "json"
require "hive/plan_review"
require "hive/plan_review/identity"

module Hive
  module PlanReview
    class Finding
      CLASSIFICATIONS = %w[safe_auto gated_auto manual fyi].freeze
      LIFECYCLES = %w[open approved answered incorporated verified resolved waived].freeze
      RESOLVED_LIFECYCLES = %w[verified resolved waived].freeze
      RISKS = %w[low medium high critical].freeze
      KEYS = %w[
        fingerprint source classification risk title description evidence lifecycle display_order
        decision_id answer incorporated_at verified_at
      ].freeze
      EVIDENCE_KEYS = %w[path start_line end_line anchor_digest excerpt].freeze

      attr_reader :data

      def self.build(attributes)
        new(attributes)
      end

      def initialize(attributes)
        @data = stringify(attributes)
        validate!
        expected = self.class.fingerprint_for(@data)
        supplied = @data["fingerprint"]
        if supplied && supplied != expected
          raise InvalidRecord, "finding fingerprint does not match semantic evidence"
        end
        @data["fingerprint"] = expected
        @data.freeze
        freeze
      end

      def fingerprint = data.fetch("fingerprint")
      def classification = data.fetch("classification")
      def lifecycle = data.fetch("lifecycle")
      def resolved? = RESOLVED_LIFECYCLES.include?(lifecycle)
      def blocking? = %w[gated_auto manual].include?(classification) && !resolved?
      def to_h = data.dup

      def [](key)
        data[key.to_s]
      end

      def self.fingerprint_for(data)
        semantic = {
          "source" => data.fetch("source").to_s.strip,
          "classification" => data.fetch("classification").to_s,
          "risk" => data.fetch("risk").to_s,
          "title" => normalize_text(data.fetch("title")),
          "description" => normalize_text(data.fetch("description")),
          "evidence" => data.fetch("evidence").slice(
            "path", "start_line", "end_line", "anchor_digest"
          )
        }
        "prf-#{Digest::SHA256.hexdigest(JSON.generate(Identity.normalize(semantic)))}"
      end

      def self.normalize_text(value)
        value.to_s.strip.gsub(/\s+/, " ")
      end
      private_class_method :normalize_text

      private

      def validate!
        unknown = data.keys - KEYS
        raise InvalidRecord, "finding has unknown fields: #{unknown.sort.join(', ')}" unless unknown.empty?

        %w[source title description].each do |key|
          value = data[key]
          unless value.is_a?(String) && !value.strip.empty?
            raise InvalidRecord, "finding #{key} must be a non-empty string"
          end
        end
        unless CLASSIFICATIONS.include?(data["classification"])
          raise InvalidRecord, "finding classification must be one of #{CLASSIFICATIONS.inspect}"
        end
        unless RISKS.include?(data["risk"])
          raise InvalidRecord, "finding risk must be one of #{RISKS.inspect}"
        end
        unless LIFECYCLES.include?(data["lifecycle"])
          raise InvalidRecord, "finding lifecycle must be one of #{LIFECYCLES.inspect}"
        end
        unless data["display_order"].is_a?(Integer) && data["display_order"].positive?
          raise InvalidRecord, "finding display_order must be a positive integer"
        end
        validate_evidence!
      end

      def validate_evidence!
        evidence = data["evidence"]
        raise InvalidRecord, "finding evidence must be a mapping" unless evidence.is_a?(Hash)

        unknown = evidence.keys - EVIDENCE_KEYS
        raise InvalidRecord, "finding evidence has unknown fields: #{unknown.sort.join(', ')}" unless unknown.empty?
        unless evidence["path"].is_a?(String) && !evidence["path"].empty? &&
               evidence["start_line"].is_a?(Integer) && evidence["start_line"].positive? &&
               evidence["end_line"].is_a?(Integer) && evidence["end_line"] >= evidence["start_line"] &&
               evidence["anchor_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidRecord, "finding evidence must have a path, valid line range, and anchor digest"
        end
      end

      def stringify(value)
        case value
        when Hash
          value.to_h { |key, child| [ key.to_s, stringify(child) ] }
        when Array then value.map { |child| stringify(child) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
