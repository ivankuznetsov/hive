require "hive/patrol_fix/migration/cutover_state"

module Hive
  module PatrolFix
    module Migration
      # Recovery policy is intentionally tiny: before the first possibly
      # mutating group boundary, rollback may advance the existing owner epoch
      # and reopen legacy discovery. Afterwards only Applier may resume.
      class ForwardRecovery
        def initialize(state:, epoch_port:, applier:, clock: -> { Time.now.utc })
          @state = state
          @epoch_port = epoch_port
          @applier = applier
          @clock = clock
        end

        def call = @applier.call

        def rollback!
          unless @state.rollback_allowed?
            raise CutoverState::ForwardOnly,
                  "Patrol-fix migration has crossed its forward-only boundary"
          end
          current = @state.read
          restored = if current.fetch("status") == "preflight"
            current.fetch("source_epochs")
          else
            @epoch_port.rollback!(
              expected: current.fetch("fenced_source_epochs"),
              ownership: current.fetch("source_ownership")
            )
          end
          @state.rollback!(source_epochs: restored, now: @clock.call)
        end
      end
    end
  end
end
