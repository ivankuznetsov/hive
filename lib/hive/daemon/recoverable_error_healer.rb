require "hive/daemon/recoverable_error_classifier"

module Hive
  module Daemon
    # Compatibility diagnostic observer. Deliberately inert with respect to
    # markers and dispatch; durable terminal attempts are reported by the
    # daemon's FailureReporter reconciliation path.
    class RecoverableErrorHealer
      def initialize(logger:, classifier: RecoverableErrorClassifier, **_options)
        @logger = logger
        @classifier = classifier
      end

      def heal(rows, now: Time.now, legacy_layout_projects: {})
        Array(rows).each do |row|
          next if legacy_layout_projects.include?(row.project)
          next unless row.marker.to_s == "error"

          code = @classifier.classify(reason: marker_reason(row), attrs: marker_attrs(row))
          @logger.event(
            :terminal_diagnostic_observed, project: row.project, slug: row.slug,
            stage: row.stage, code: code, route: "coordinator", at: now.utc.iso8601
          )
        end
      end

      private

      def marker_attrs(row)
        row.respond_to?(:marker_attrs) && row.marker_attrs.is_a?(Hash) ? row.marker_attrs : {}
      end

      def marker_reason(row) = marker_attrs(row)["reason"].to_s
    end
  end
end
