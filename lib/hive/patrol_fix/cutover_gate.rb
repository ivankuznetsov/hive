module Hive
  module PatrolFix
    # U2 installs the new lane inert. U9 may construct an enabled gate only
    # after its persisted epoch fence is committed; there is intentionally no
    # environment-variable escape hatch that could activate dual writers.
    class CutoverGate
      attr_reader :epoch

      def initialize(enabled: false, epoch: nil)
        @enabled = enabled == true
        @epoch = epoch&.to_s
        if @enabled && (@epoch.nil? || @epoch.empty? || @epoch.bytesize > 128)
          raise ArgumentError, "enabled Patrol Fix cutover requires a bounded epoch"
        end
        freeze
      end

      def enabled? = @enabled
    end
  end
end
