module Hive
  class UserService
    class Result
      KINDS = %i[
        absent
        autostart_unavailable
        drifted
        failed
        partial
        removed
        stale
        unchanged
        unsafe_path
        unsupported
        upgraded
        written
      ].freeze
      SUCCESS_KINDS = %i[
        absent
        autostart_unavailable
        removed
        unchanged
        unsupported
        upgraded
        written
      ].freeze

      attr_reader :kind, :operation, :backup_path, :restarted, :final_status,
                  :diagnostics, :error_class

      def initialize(kind, operation: :apply, backup_path: nil, restarted: false,
                     final_status: nil, diagnostics: [], error: nil)
        @kind = kind.to_sym
        raise ArgumentError, "unknown user service result #{@kind.inspect}" unless KINDS.include?(@kind)

        @operation = operation.to_sym
        @backup_path = backup_path
        @restarted = !!restarted
        @final_status = final_status
        @diagnostics = diagnostics.map(&:to_sym).uniq.freeze
        @error_class = error&.class&.name
        freeze
      end

      def success?
        SUCCESS_KINDS.include?(kind)
      end

      def drifted?
        kind == :drifted
      end

      def failed?
        %i[failed partial stale unsafe_path].include?(kind)
      end
    end
  end
end
