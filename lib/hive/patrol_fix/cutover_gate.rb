module Hive
  module PatrolFix
    # U2 installs the new lane inert. U9 may construct an enabled gate only
    # after its persisted epoch fence is committed; there is intentionally no
    # environment-variable escape hatch that could activate dual writers.
    class CutoverGate
      def self.for_project(project_root:, hive_state_path:, source:)
        project_root = File.expand_path(project_root)
        state_root = File.expand_path(hive_state_path || ".hive-state", project_root)
        cutover_root = File.join(state_root, "patrol-fix", "migration")
        new(loader: lambda do
          require "hive/patrol_fix/migration/cutover_state"
          Hive::PatrolFix::Migration::CutoverState.new(
            root: cutover_root
          ).gate_for(source)
        end)
      end

      def initialize(enabled: false, epoch: nil, loader: nil)
        @enabled = enabled == true
        @epoch = epoch&.to_s
        @loader = loader
        if @enabled && (@epoch.nil? || @epoch.empty? || @epoch.bytesize > 128)
          raise ArgumentError, "enabled Patrol Fix cutover requires a bounded epoch"
        end
        freeze
      end

      def enabled?
        return @enabled unless @loader

        @loader.call.enabled?
      end

      def epoch
        return @epoch unless @loader

        @loader.call.epoch
      end
    end
  end
end
