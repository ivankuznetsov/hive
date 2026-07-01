module Hive
  module Daemon
    # Pure allowlist classifier for terminal ERROR markers that may be
    # retried after an external dependency becomes healthy again.
    module RecoverableErrorClassifier
      CODEX_AUTH_401 = /401/.freeze
      CODEX_AUTH_TEXT = /missing\s+bearer|basic\s+auth/i.freeze

      # The closed set of recoverable categories this classifier can emit.
      # Single source of truth: `HealthProbe` and `HealthSignal` each branch
      # on every member, so a new category is added here and wired into both
      # of those `case` statements together — a missing branch falls through
      # to their `unknown_reason` arm rather than being silently mishandled.
      CATEGORIES = %i[codex_auth claude_launcher].freeze

      module_function

      # `reason` is the marker's `reason=` attribute; `attrs` the marker's
      # other attributes. Returns a member of CATEGORIES or nil. (Stage and
      # workflow are not consulted — the allowlist is purely reason/attrs.)
      def classify(reason:, attrs:)
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
