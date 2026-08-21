require "hive/patrol_fix"
require "hive/patrol_fix/report_reader"

module Hive
  module PatrolFix
    class InboxReport
      SCHEMA = "hive-patrol-fix-inbox-report".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = ReportReader::MAX_BYTES
      MAX_TEXT_BYTES = ReportReader::MAX_TEXT_BYTES
      MAX_EVIDENCE = ReportReader::MAX_EVIDENCE
      ROUTES = %w[fix escalate reject blocked].freeze
      FIELDS = ReportReader::FIELDS

      class InvalidReport < Hive::Error; end

      attr_reader :route, :rationale, :evidence, :blocker_owner

      def self.read(path)
        new(**ReportReader.read(
          path,
          label: "inbox report",
          error_class: InvalidReport,
          schema: SCHEMA,
          schema_version: SCHEMA_VERSION,
          routes: ROUTES, known_routes: ROUTES
        ))
      end

      def self.parse(source)
        new(**ReportReader.parse(
          source,
          label: "inbox report",
          error_class: InvalidReport,
          schema: SCHEMA,
          schema_version: SCHEMA_VERSION,
          routes: ROUTES, known_routes: ROUTES
        ))
      end

      def initialize(route:, rationale:, evidence:, blocker_owner:)
        @route = route.freeze
        @rationale = rationale.freeze
        @evidence = evidence.dup.freeze
        @blocker_owner = blocker_owner.freeze
        freeze
      end

      def to_h
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "route" => route, "rationale" => rationale,
          "evidence" => evidence, "blocker_owner" => blocker_owner
        }
      end
    end
  end
end
