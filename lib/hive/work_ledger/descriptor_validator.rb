module Hive
  module WorkLedger
    # Structural validation for an ordered stage descriptor. Names, kinds, and
    # transitions remain caller vocabulary; this class only enforces identity,
    # contiguous topology, uniqueness, and a well-formed first stage.
    class DescriptorValidator
      class << self
        def validate(identity:, stages:, allowed_kinds:)
          new(identity: identity, stages: stages, allowed_kinds: allowed_kinds).validate
        end
      end

      def initialize(identity:, stages:, allowed_kinds:)
        @identity = identity
        @stages = stages
        @allowed_kinds = allowed_kinds
      end

      def validate
        validate_identity!
        unless stages.is_a?(Array) && !stages.empty?
          raise InvalidDescriptor, "must declare at least one stage"
        end
        unless allowed_kinds.is_a?(Array) && !allowed_kinds.empty?
          raise InvalidRequest, "allowed_kinds must be a non-empty array"
        end

        normalized = stages.map.with_index { |stage, index| normalize_stage(stage, index) }
        expected = (1..normalized.length).to_a
        actual = normalized.map { |stage| stage.fetch(:index) }
        unless actual == expected
          raise InvalidDescriptor,
                "stage indices must be #{expected.inspect} in order, got #{actual.inspect}"
        end

        reject_duplicates!(normalized.map { |stage| stage.fetch(:name) }, "stage names")
        reject_duplicates!(normalized.map { |stage| stage.fetch(:dir) }, "stage dirs")
        validate_kinds!(normalized)

        first = normalized.first
        unless first.fetch(:advance_verb).nil?
          raise InvalidDescriptor,
                "first stage #{first.fetch(:name).inspect} must not declare an " \
                "advance_verb (no stage precedes it to advance from)"
        end

        DescriptorReceipt.new(
          identity: immutable(identity.to_s),
          stage_names: normalized.map { |stage| immutable(stage.fetch(:name)) }.freeze,
          stage_dirs: normalized.map { |stage| immutable(stage.fetch(:dir)) }.freeze
        )
      end

      private

      attr_reader :identity, :stages, :allowed_kinds

      def validate_identity!
        unless (identity.is_a?(String) || identity.is_a?(Symbol)) && !identity.to_s.empty?
          raise InvalidDescriptor, "descriptor identity must be a non-empty string or symbol"
        end
      end

      def normalize_stage(stage, offset)
        unless stage.is_a?(Hash)
          raise InvalidDescriptor, "stage #{offset + 1} must be a mapping"
        end

        name = value(stage, :name)
        dir = value(stage, :dir)
        unless name.is_a?(String) && !name.empty?
          raise InvalidDescriptor, "stage #{offset + 1} name must be a non-empty string"
        end
        unless dir.is_a?(String) && !dir.empty?
          raise InvalidDescriptor, "stage #{name.inspect} dir must be a non-empty string"
        end

        {
          name: name,
          index: value(stage, :index),
          dir: dir,
          kind: value(stage, :kind),
          advance_verb: value(stage, :advance_verb)
        }
      end

      def value(stage, key)
        stage.key?(key) ? stage[key] : stage[key.to_s]
      end

      def reject_duplicates!(values, label)
        return if values.uniq.length == values.length

        raise InvalidDescriptor, "has duplicate #{label}: #{values.inspect}"
      end

      def validate_kinds!(normalized)
        normalized.each do |stage|
          next if allowed_kinds.include?(stage.fetch(:kind))

          raise InvalidDescriptor,
                "stage #{stage.fetch(:name).inspect} has unknown kind " \
                "#{stage.fetch(:kind).inspect} " \
                "(known: #{allowed_kinds.map(&:inspect).join(', ')})"
        end
      end

      def immutable(value)
        value.dup.freeze
      end
    end
  end
end
