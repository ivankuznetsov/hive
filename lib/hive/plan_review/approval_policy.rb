require "time"
require "hive/canonical_json"
require "hive/plan_review/finding"

module Hive
  module PlanReview
    module ApprovalPolicy
      Match = Data.define(:policy, :receipt)

      module_function

      def match(finding:, policies:, review_id:, policy_fingerprint:, now: Time.now.utc,
                policy_id: nil, policy_version: nil)
        finding = finding.is_a?(Finding) ? finding : Finding.new(finding)
        Array(policies).each do |entry|
          policy = stringify(entry)
          next if policy_id && policy["id"] != policy_id.to_s
          next if policy_version && policy["version"] != Integer(policy_version)
          next unless applicable?(policy, finding, now)

          receipt = {
            "policy_id" => policy.fetch("id"), "policy_version" => policy.fetch("version"),
            "policy_digest" => Hive::CanonicalJSON.digest(policy),
            "action" => "approve_finding", "risk" => finding["risk"],
            "path" => finding["evidence"].fetch("path"),
            "review_id" => review_id, "policy_fingerprint" => policy_fingerprint,
            "matched_at" => now.utc.iso8601(6)
          }.freeze
          return Match.new(policy: policy.freeze, receipt:).freeze
        end
        nil
      rescue ArgumentError, TypeError
        nil
      end

      def applicable?(policy, finding, now)
        return false if policy["revoked"] == true
        return false unless policy["action"] == "approve_finding"
        return false unless policy["risk"] == finding["risk"]
        return false unless Time.iso8601(policy.fetch("valid_from")) <= now
        return false unless now <= Time.iso8601(policy.fetch("valid_until"))

        path = finding["evidence"].fetch("path")
        Array(policy["paths"]).one? { |candidate| exact_path?(candidate, path) }
      rescue ArgumentError, KeyError, TypeError
        false
      end
      private_class_method :applicable?

      def exact_path?(candidate, path)
        candidate = candidate.to_s.tr("\\", "/")
        !candidate.match?(/[?*\[\]{}]/) && candidate == path.to_s.tr("\\", "/")
      end
      private_class_method :exact_path?

      def stringify(value)
        value.to_h { |key, child| [ key.to_s, child ] }
      end
      private_class_method :stringify
    end
  end
end
