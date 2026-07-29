require "hive/managed_directory"

module Hive
  module RefactorPatrol
    # Stable lock outside the replaceable JobStore root. Both forward migration
    # and explicit reverse restore use it, so swapping the root cannot swap away
    # the lock authority that fences the operation.
    module JobSchemaTransitionLock
      module_function

      def with_lock(root, &block)
        directory = Hive::ManagedDirectory.new(
          root: File.dirname(File.expand_path(root)),
          label: "refactor patrol job schema transition"
        )
        directory.with_lock(
          ".job-schema-transition.lock",
          shared: false,
          &block
        )
      end
    end
  end
end
