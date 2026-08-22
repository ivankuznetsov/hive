require "digest"
require "json"
require "time"
require "hive/refactor_patrol/agent_identity"

module Hive
  module RefactorPatrol
    # Immutable discovery snapshot retained in the v4 job envelope. The action
    # fields preserve the released record shape for readers; no runtime
    # component interprets them as mutation authority.
    module Policy
      CAP_BOOLEANS = %w[
        single_feature_only allow_dependency_bumps allow_public_api_changes
        allow_cross_feature
      ].freeze

      module_function

      def capture(cfg, now: Time.now)
        refactor = cfg.fetch("refactor_patrol")
        identity = Hive::RefactorPatrol::AgentIdentity.new(cfg: cfg).fix
        action = {
          "default_branch" => cfg.fetch("default_branch").to_s,
          "auto_fix_agent" => identity.provider.to_s,
          "auto_fix_model" => identity.model.to_s,
          "auto_fix_effort" => identity.requested_effort,
          "auto_fix_launcher_identity" => identity.launcher_identity.to_s,
          "min_confidence" => refactor.fetch("min_confidence").to_s,
          "commands" => json_copy(refactor.fetch("commands")),
          "caps" => CAP_BOOLEANS.to_h do |key|
            [ key, refactor.fetch("caps").fetch(key) ]
          end
        }
        {
          "discovery" => refactor.fetch("enabled") == true,
          "auto_fix" => false,
          "issue_filing" => false,
          "action" => action,
          "epoch" => ::Digest::SHA256.hexdigest(JSON.generate(action)),
          "captured_at" => now.utc.iso8601
        }
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end
      private_class_method :json_copy
    end
  end
end
