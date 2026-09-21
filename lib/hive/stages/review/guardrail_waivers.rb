require "set"

module Hive
  module Stages
    module Review
      # One parser for the operator-owned exact waivers consumed by both the
      # pre-fix residue checkpoint and the post-fix diff guardrail. Keeping the
      # gates on one set is important: otherwise CleanExit can refuse the very
      # fingerprint the later guardrail was explicitly configured to waive.
      module GuardrailWaivers
        SHA256 = /\A[0-9a-f]{64}\z/.freeze

        module_function

        def resolve(cfg)
          values = Array(cfg.dig("review", "fix", "guardrail", "waivers"))
          values.each_with_object(Set.new) do |value, result|
            unless value.is_a?(Hash)
              raise Hive::ConfigError,
                    "review.fix.guardrail.waivers entries must contain pattern and sha256"
            end

            pattern = (value["pattern"] || value[:pattern]).to_s
            sha256 = (value["sha256"] || value[:sha256]).to_s.downcase
            if pattern.empty? || !SHA256.match?(sha256)
              raise Hive::ConfigError,
                    "review.fix.guardrail.waivers entries must contain pattern and SHA-256"
            end

            result.add([ pattern, sha256 ])
          end.freeze
        end
      end
    end
  end
end
