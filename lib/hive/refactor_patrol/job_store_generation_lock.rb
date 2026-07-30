require "hive/managed_directory"

module Hive
  module RefactorPatrol
    # Stable lock outside both versioned JobStore roots. Reset can replace the
    # released jobs name and prepare v3 without replacing its own authority.
    module JobStoreGenerationLock
      module_function

      def with_lock(state_root, &block)
        directory = Hive::ManagedDirectory.new(
          root: File.join(
            File.expand_path(state_root), "refactor_patrol"
          ),
          label: "refactor patrol JobStore generation"
        )
        directory.prepare!
        directory.with_lock(
          ".jobstore-generation.lock",
          shared: false,
          &block
        )
      end
    end
  end
end
