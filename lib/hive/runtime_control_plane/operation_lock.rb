require "hive/paths"
require "hive/runtime_control_plane/file_fence"

module Hive
  module RuntimeControlPlane
    class OperationLock < FileFence
      def initialize(state_home: Hive::Paths.state_home, timeout_sec: 30, **options)
        super(
          path: Hive::Paths.runtime_quiescence_operation_lock_path(state_home),
          timeout_sec: timeout_sec, **options
        )
      end
    end
  end
end
