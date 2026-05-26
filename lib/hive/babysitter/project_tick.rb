module Hive
  module Babysitter
    module ProjectTick
      module_function

      def run(_project_entry, _cfg, dry_run:, logger:, inflight:)
        # Implemented in the PR-processing unit. The lifecycle shell
        # calls through this seam so tests can drive the dispatcher
        # without touching GitHub.
        true
      end
    end
  end
end
