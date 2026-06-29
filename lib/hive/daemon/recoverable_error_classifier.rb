module Hive
  module Daemon
    # Pure allowlist classifier for terminal ERROR markers that may be
    # retried after an external dependency becomes healthy again.
    module RecoverableErrorClassifier
      CODEX_AUTH_401 = /401/.freeze
      CODEX_AUTH_TEXT = /missing\s+bearer|basic\s+auth/i.freeze

      module_function

      def classify(reason:, attrs:, stage: nil, workflow: nil)
        attrs = attrs.is_a?(Hash) ? attrs : {}

        case reason.to_s
        when "implementer_failed"
          classify_implementer_failed(attrs)
        when "claude_launch_failed"
          :claude_launcher
        else
          nil
        end
      end

      def classify_implementer_failed(attrs)
        provider = attrs["provider"] || attrs[:provider]
        return nil unless provider.nil? || provider.to_s == "codex"

        message = (attrs["message"] || attrs[:message]).to_s
        return nil unless message.match?(CODEX_AUTH_401)
        return nil unless message.match?(CODEX_AUTH_TEXT)

        :codex_auth
      end
    end
  end
end
