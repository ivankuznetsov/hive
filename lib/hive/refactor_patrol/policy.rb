require "json"
require "digest"
require "time"

module Hive
  module RefactorPatrol
    # Captures the complete action authority used by a merged-PR occurrence
    # and intersects it with current configuration. Current policy can revoke
    # or narrow work, but can never grant an older job new authority.
    module Policy
      CONFIDENCE = %w[low medium high].freeze
      COMMANDS = %w[docs format lint public_contract typecheck test].freeze
      CAP_BOOLEANS = %w[
        single_feature_only allow_dependency_bumps allow_public_api_changes
        allow_cross_feature
      ].freeze

      Result = Struct.new(:config, :authority, :reasons, :error, keyword_init: true) do
        def authorized?(kind)
          authority.fetch(kind.to_s, false)
        end
      end

      module_function

      def capture(cfg, now: Time.now)
        refactor = cfg.fetch("refactor_patrol")
        action = {
          "default_branch" => cfg.fetch("default_branch").to_s,
          "auto_fix_agent" => refactor.dig("auto_fix", "agent").to_s,
          "min_confidence" => refactor.fetch("min_confidence").to_s,
          "commands" => json_copy(refactor.fetch("commands")),
          "caps" => CAP_BOOLEANS.to_h do |key|
            [ key, refactor.fetch("caps").fetch(key) ]
          end,
          "issue_min_leverage_score" => refactor.dig(
            "issue_filing", "min_leverage_score"
          ).to_f
        }
        {
          "discovery" => refactor.fetch("enabled") == true,
          "auto_fix" => refactor.dig("auto_fix", "enabled") == true,
          "issue_filing" => refactor.dig("issue_filing", "enabled") == true,
          "action" => action,
          "epoch" => ::Digest::SHA256.hexdigest(JSON.generate(action)),
          "captured_at" => now.utc.iso8601
        }
      end

      def intersect(snapshot, current_cfg)
        effective = json_copy(current_cfg)
        authority = { "fix" => false, "issue" => false }
        reasons = { "fix" => [], "issue" => [] }
        action = snapshot["action"] if snapshot.is_a?(Hash)
        unless action.is_a?(Hash)
          return Result.new(
            config: effective, authority: authority, reasons: reasons,
            error: "policy_snapshot_missing"
          )
        end

        current = current_cfg.fetch("refactor_patrol")
        target = effective.fetch("refactor_patrol")
        discovery = snapshot["discovery"] == true && current["enabled"] == true
        fix_enabled = discovery && snapshot["auto_fix"] == true &&
                      current.dig("auto_fix", "enabled") == true
        issue_enabled = discovery && snapshot["issue_filing"] == true &&
                        current.dig("issue_filing", "enabled") == true

        target["enabled"] = discovery
        target.fetch("auto_fix")["enabled"] = fix_enabled
        target.fetch("issue_filing")["enabled"] = issue_enabled

        target["min_confidence"] = stricter_confidence(
          action.fetch("min_confidence"), current.fetch("min_confidence")
        )
        target.fetch("issue_filing")["min_leverage_score"] = [
          Float(action.fetch("issue_min_leverage_score")),
          Float(current.dig("issue_filing", "min_leverage_score"))
        ].max
        intersect_caps!(target.fetch("caps"), action.fetch("caps"), current.fetch("caps"))

        commands_match = intersect_commands!(
          target.fetch("commands"), action.fetch("commands"), current.fetch("commands")
        )
        snapshot_agent = action.fetch("auto_fix_agent").to_s
        current_agent = current.dig("auto_fix", "agent").to_s
        agent_match = !snapshot_agent.empty? && snapshot_agent == current_agent
        branch_match = action.fetch("default_branch").to_s == current_cfg.fetch("default_branch").to_s
        target.fetch("auto_fix")["agent"] = snapshot_agent

        reasons.fetch("fix") << "validation_commands_changed" unless commands_match
        reasons.fetch("fix") << "auto_fix_agent_changed" unless agent_match
        reasons.fetch("fix") << "default_branch_changed" unless branch_match
        authority["fix"] = fix_enabled && commands_match && agent_match && branch_match
        authority["issue"] = issue_enabled

        Result.new(config: effective, authority: authority, reasons: reasons, error: nil)
      rescue KeyError, TypeError, ArgumentError
        Result.new(
          config: effective || json_copy(current_cfg),
          authority: { "fix" => false, "issue" => false },
          reasons: { "fix" => [], "issue" => [] },
          error: "policy_snapshot_invalid"
        )
      end

      def stricter_confidence(snapshot, current)
        snapshot_index = CONFIDENCE.index(snapshot.to_s)
        current_index = CONFIDENCE.index(current.to_s)
        raise ArgumentError, "unknown confidence" unless snapshot_index && current_index

        CONFIDENCE.fetch([ snapshot_index, current_index ].max)
      end
      private_class_method :stricter_confidence

      def intersect_caps!(target, snapshot, current)
        target.delete("max_files")
        target.delete("max_diff_lines")
        target["single_feature_only"] = snapshot.fetch("single_feature_only") == true ||
                                         current.fetch("single_feature_only") == true
        %w[allow_dependency_bumps allow_public_api_changes allow_cross_feature].each do |key|
          target[key] = snapshot.fetch(key) == true && current.fetch(key) == true
        end
      end
      private_class_method :intersect_caps!

      def intersect_commands!(target, snapshot, current)
        match = true
        COMMANDS.each do |key|
          before = snapshot[key]
          now = current[key]
          target[key] = before == now ? before : nil
          match = false unless before == now
        end
        match
      end
      private_class_method :intersect_commands!

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end
      private_class_method :json_copy
    end
  end
end
