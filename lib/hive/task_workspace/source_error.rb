require "hive"
require "hive/secret_patterns"

module Hive
  module TaskWorkspace
    class SourceError < Hive::Error
      attr_reader :source, :reason, :details

      def initialize(source:, reason:, message: nil, details: {})
        @source = source.to_s
        @reason = reason.to_s
        @details = details.to_h.transform_keys(&:to_s)
        super(Hive::SecretPatterns.redact(message || @reason))
      end

      def diagnostic
        {
          "source" => source,
          "reason" => reason,
          "message" => message,
          "details" => details
        }
      end
    end
  end
end
