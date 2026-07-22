require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/base_state_store"

module Hive
  module Patrol
    class StateStore < BaseStateStore
      def initialize(project_root)
        super(project_root, state_directory: "patrol", collections: %w[features findings patches reports runs])
      end

      def write_feature(feature)
        write_record("features", feature)
      end

      def write_finding(finding)
        write_record("findings", finding)
      end

      def findings
        Dir.glob(File.join(root, "findings", "*.json")).sort.filter_map do |path|
          data = read_json(path)
          Finding.from_h(data) unless data.empty?
        rescue KeyError, ArgumentError
          nil
        end
      end

      def transition_finding(id, state:, reason:, now: Time.now, superseded_by: nil)
        unless Finding::LIFECYCLE_STATES.include?(state.to_s)
          raise ArgumentError, "unsupported patrol finding lifecycle state #{state.inspect}"
        end

        finding = findings.find { |candidate| candidate.id.to_s == id.to_s }
        return unless finding
        return finding if finding.lifecycle_state == state.to_s &&
                          finding.lifecycle_reason == reason.to_s &&
                          finding.superseded_by.to_s == superseded_by.to_s

        finding.lifecycle_state = state.to_s
        finding.lifecycle_reason = reason.to_s
        finding.lifecycle_updated_at = now.utc.iso8601
        finding.superseded_by = superseded_by unless superseded_by.to_s.empty?
        finding.superseded_by = nil unless state.to_s == "superseded"
        write_finding(finding)
      end

      def write_patch(id, data)
        write_json(File.join(root, "patches", "#{id}.json"), data)
      end
    end
  end
end
