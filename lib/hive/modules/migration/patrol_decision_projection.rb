require "hive/errors"

module Hive
  module Modules
    module Migration
      class PatrolDecisionProjection < Data.define(
        :module_name, :rationale, :job_id, :phase
      )
        MODULES = %w[patrol architecture-patrol].freeze
        ORDINARY_RATIONALES = %w[disabled not_due due].freeze
        ARCHITECTURE_RATIONALES = %w[not_due due].freeze
        ARCHITECTURE_PHASES = %w[discovery action].freeze
        KEYS = %w[job_id module phase rationale].freeze

        class << self
          def build(module_name:, rationale:, job_id: nil, phase: nil)
            module_name = module_name.to_s
            rationale = rationale.to_s
            malformed! unless MODULES.include?(module_name)

            if module_name == "patrol"
              malformed! unless ORDINARY_RATIONALES.include?(rationale) &&
                                job_id.nil? && phase.nil?
            else
              malformed! unless ARCHITECTURE_RATIONALES.include?(rationale)
              if rationale == "due"
                job_id = nonempty(job_id)
                phase = phase.to_s
                malformed! unless ARCHITECTURE_PHASES.include?(phase)
              else
                malformed! unless job_id.nil? && phase.nil?
              end
            end

            new(
              module_name: module_name.freeze,
              rationale: rationale.freeze,
              job_id: job_id&.dup&.freeze,
              phase: phase&.dup&.freeze
            ).freeze
          end

          def from_h(value)
            malformed! unless value.is_a?(Hash) &&
                              value.keys.sort == KEYS
            build(
              module_name: value["module"],
              rationale: value["rationale"],
              job_id: value["job_id"],
              phase: value["phase"]
            )
          end

          def coerce(value)
            from_h(value.is_a?(self) ? value.to_h : value)
          end

          private

          def nonempty(value)
            string = value.to_s
            malformed! if string.empty?
            string
          end

          def malformed!
            raise Hive::ConfigError,
                  "patrol decision projection is malformed"
          end
        end

        def to_h
          {
            "module" => module_name,
            "rationale" => rationale,
            "job_id" => job_id,
            "phase" => phase
          }.freeze
        end
      end
    end
  end
end
