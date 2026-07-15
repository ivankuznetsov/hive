require "hive"

module Hive
  module WorkflowPackage
    Diagnostic = Data.define(:rule_id, :severity, :path, :line, :column, :message) do
      SEVERITIES = %i[error warning].freeze

      def initialize(rule_id:, severity:, path:, line: nil, column: nil, message:)
        severity = severity.to_sym
        raise ArgumentError, "unknown diagnostic severity #{severity.inspect}" unless SEVERITIES.include?(severity)

        super(
          rule_id: rule_id.to_s.freeze,
          severity: severity,
          path: path.to_s.freeze,
          line: line,
          column: column,
          message: message.to_s.freeze
        )
      end

      def error? = severity == :error
      def warning? = severity == :warning

      def to_h
        {
          "rule" => rule_id,
          "severity" => severity.to_s,
          "path" => path,
          "line" => line,
          "column" => column,
          "message" => message
        }.compact
      end

      def to_s
        location = [ path, line, column ].compact.join(":")
        "#{severity}: #{rule_id} at #{location}: #{message}"
      end
    end

    class PackageError < Hive::ConfigError
      attr_reader :diagnostic

      def initialize(diagnostic)
        @diagnostic = diagnostic
        super(diagnostic.to_s)
      end
    end
  end
end
