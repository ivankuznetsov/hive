require "hive/terminal_error_registry"

module Hive
  module Daemon
    # Legacy name retained for callers; classification is diagnostic-only and
    # cannot express retry eligibility or policy.
    module RecoverableErrorClassifier
      module_function

      def classify(reason:, attrs:)
        Hive::TerminalErrorRegistry.normalize(reason, attrs || {})
      end
    end
  end
end
