require "json"
require "hive/refactor_patrol/fingerprint"

module Hive
  module RefactorPatrol
    class Collisions
      Result = Struct.new(:thesis, :suppressed, :reason, :reference, keyword_init: true)

      def initialize(project_root, state:, v2_fingerprints: {})
        @project_root = File.expand_path(project_root)
        @state = state
        @v2_fingerprints = v2_fingerprints || {}
      end

      def check(thesis)
        own = own_collision(thesis)
        return own if own

        patrol = patrol_collision(thesis)
        if patrol
          thesis.risk["flags"] |= [ "collision_patrol_pr" ]
          thesis.collision = { "kind" => "collision_patrol_pr", "reference" => patrol }
          return Result.new(thesis: thesis, suppressed: false, reason: "collision_patrol_pr", reference: patrol)
        end

        Result.new(thesis: thesis, suppressed: false)
      end

      private

      def own_collision(thesis)
        fingerprints = @state.fingerprints
        dismissed = @state.dismissed
        if @v2_fingerprints.key?(thesis.fingerprint)
          thesis.collision = { "kind" => "collision_already_seen", "reference" => thesis.fingerprint }
          return Result.new(
            thesis: thesis, suppressed: true,
            reason: "collision_already_seen", reference: thesis.fingerprint
          )
        end
        if Fingerprint.known_active?(fingerprints, thesis.fingerprint)
          thesis.collision = { "kind" => "collision_already_seen", "reference" => thesis.fingerprint }
          return Result.new(thesis: thesis, suppressed: true, reason: "collision_already_seen", reference: thesis.fingerprint)
        end

        if Fingerprint.dismissed?(dismissed, thesis.fingerprint)
          thesis.collision = { "kind" => "collision_dismissed", "reference" => thesis.fingerprint }
          return Result.new(thesis: thesis, suppressed: true, reason: "collision_dismissed", reference: thesis.fingerprint)
        end

        if Fingerprint.similar_known?(fingerprints, dismissed, thesis)
          thesis.collision = { "kind" => "collision_similar_known", "reference" => thesis.fingerprint }
          return Result.new(thesis: thesis, suppressed: true, reason: "collision_similar_known", reference: thesis.fingerprint)
        end

        nil
      end

      def patrol_collision(thesis)
        patrol_fingerprints.values.find do |entry|
          %w[open merged review_handoff_failed].include?(entry["state"].to_s) &&
            entry["feature_id"].to_s == thesis.feature_id.to_s
        end&.then { |entry| entry["pr_url"].to_s.empty? ? entry["state"].to_s : entry["pr_url"].to_s }
      end

      def patrol_fingerprints
        path = File.join(@project_root, ".hive-state", "patrol", "fingerprints.json")
        return {} unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end
    end
  end
end
