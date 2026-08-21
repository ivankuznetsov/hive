require "hive/patrol_fix"
require "hive/patrol_fix/report_reader"

module Hive
  module PatrolFix
    # Strict model-output value for the independent Patrol Fix review gate.
    # Controller identity, evidence, diff, validation and HEAD are deliberately
    # absent: Review resolves and binds those values after parsing this report.
    class ReviewReceipt
      SCHEMA = "hive-patrol-fix-review-report".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = ReportReader::MAX_BYTES
      MAX_TEXT_BYTES = ReportReader::MAX_TEXT_BYTES
      MAX_EVIDENCE = ReportReader::MAX_EVIDENCE
      ROUTES = %w[publish rework escalate reject blocked].freeze
      FIELDS = ReportReader::FIELDS

      class InvalidReport < Hive::Error; end

      attr_reader :route, :rationale, :evidence, :blocker_owner

      def self.read(path, allowed_routes: ROUTES)
        new(**ReportReader.read(
          path,
          label: "review report",
          error_class: InvalidReport,
          schema: SCHEMA,
          schema_version: SCHEMA_VERSION,
          routes: allowed_routes, known_routes: ROUTES
        ))
      end

      def self.parse(source, allowed_routes: ROUTES)
        new(**ReportReader.parse(
          source,
          label: "review report",
          error_class: InvalidReport,
          schema: SCHEMA,
          schema_version: SCHEMA_VERSION,
          routes: allowed_routes, known_routes: ROUTES
        ))
      end

      def initialize(route:, rationale:, evidence:, blocker_owner:)
        @route = route.freeze
        @rationale = rationale.freeze
        @evidence = evidence.dup.freeze
        @blocker_owner = blocker_owner.freeze
        freeze
      end
    end
  end
end
