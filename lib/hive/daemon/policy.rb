module Hive
  module Daemon
    # Pure decision module: maps a `hive status --json` task row's
    # `action` field (a `Hive::Schemas::TaskActionKind` value) plus
    # state-file mtime context to one of four outcomes:
    #
    #   :dispatch          — run `row.suggested_command` as a child
    #   :poll_for_merge    — hand off to PrMergeWatcher (6-pr → 7-done)
    #   :wait_for_debounce — user is mid-edit; let mtime settle
    #   :skip              — do nothing this tick
    #
    # The daemon adds NO new approval logic. Forward-advance safety is
    # delegated to `Hive::Commands::Approve::VALID_TERMINAL_MARKERS`
    # (the closed terminal-marker set already enforced by `hive approve`
    # and the workflow verbs the daemon dispatches). That check refuses
    # to advance on `:waiting` / `:execute_waiting` / `:review_waiting`
    # / `:execute_stale` / `:review_*_stale` / `:review_error` / `:error`,
    # so the daemon can dispatch confidently knowing a misclassified row
    # will fail loudly with `Hive::WrongStage` (exit 4) at the workflow-
    # verb level rather than silently advancing past a human gate.
    #
    # The only non-marker-driven decision is the `:edit` debounce: when
    # the task is in a `:waiting` state, the daemon dispatches only if
    # the state-file mtime moved since the last dispatch AND
    # `now - mtime >= edit_debounce_sec` (so a partial mid-save draft
    # doesn't trigger an early dispatch). First sight (no prior dispatch
    # recorded) dispatches when the file has been settled long enough.
    module Policy
      module_function

      # Actions that mean "the task is ready to advance to the next stage".
      # The daemon dispatches `row.suggested_command` (which is the
      # promote-or-run workflow verb produced by `Hive::TaskAction`).
      ADVANCE_ACTIONS = %w[
        ready_to_brainstorm
        ready_to_plan
        ready_to_develop
        ready_for_review
        ready_for_pr
      ].freeze

      # Action that means "task is at 6-pr, waiting for the human to merge
      # the PR on GitHub". Daemon hands off to PrMergeWatcher (U10) which
      # polls `gh pr view --json state` and dispatches `hive archive` on
      # `MERGED`.
      MERGE_WAIT_ACTION = "ready_to_archive".freeze

      # Actions that mean "the task is in a stage and ready to RE-RUN with
      # fresh user input from the state file". Detection is mtime-debounced
      # so a mid-save partial draft doesn't trigger an early dispatch.
      EDIT_RESUME_ACTIONS = %w[
        needs_input
        review_findings
      ].freeze

      # Decide what to do with one task row.
      #
      # @param action [String] the `tasks[].action` value from hive-status JSON
      # @param command [String, nil] the `suggested_command` for the row (may be nil)
      # @param state_file_mtime [Time, nil] mtime of the task's state file
      # @param last_dispatched_state_file_mtime [Time, nil] mtime captured at the
      #   last successful dispatch on this (project, slug); nil = no prior dispatch
      # @param now [Time] current time (injected for testability)
      # @param edit_debounce_sec [Integer] minimum age of mtime before a
      #   `:edit`-class row is eligible for dispatch (default 30s)
      #
      # @return [Symbol] one of :dispatch, :poll_for_merge, :wait_for_debounce, :skip
      def decide(action:, command:, state_file_mtime:, last_dispatched_state_file_mtime:,
                 now:, edit_debounce_sec: 30)
        return :skip if action.nil?
        return :skip if (advance?(action) || edit_resume?(action)) && (command.nil? || command.empty?)

        if advance?(action)
          :dispatch
        elsif action == MERGE_WAIT_ACTION
          :poll_for_merge
        elsif edit_resume?(action)
          decide_edit(state_file_mtime: state_file_mtime,
                      last_dispatched: last_dispatched_state_file_mtime,
                      now: now,
                      debounce_sec: edit_debounce_sec)
        else
          # `recover_execute` / `recover_review` / `agent_running` /
          # `archived` / `error` plus any unknown future TaskActionKind
          # value. Forward-compat: unknown actions are treated as skip
          # rather than dispatched, matching the closed-default policy
          # used in `Hive::Schemas::NextActionKind` consumers.
          :skip
        end
      end

      def advance?(action)
        ADVANCE_ACTIONS.include?(action)
      end

      def edit_resume?(action)
        EDIT_RESUME_ACTIONS.include?(action)
      end

      def decide_edit(state_file_mtime:, last_dispatched:, now:, debounce_sec:)
        return :skip if state_file_mtime.nil?

        if last_dispatched.nil?
          # First sight of this task — fresh `mv`-into-stage, brand-new
          # 1-inbox idea, or a daemon-restart on an existing :waiting
          # task. The mtime check still applies so a mid-edit save
          # doesn't fire prematurely; once the file has been settled for
          # at least `debounce_sec` we dispatch.
          return :wait_for_debounce if (now - state_file_mtime) < debounce_sec

          return :dispatch
        end

        # Subsequent visits: only re-fire if the user has actually edited
        # the state file since our last dispatch.
        return :skip if state_file_mtime <= last_dispatched

        return :wait_for_debounce if (now - state_file_mtime) < debounce_sec

        :dispatch
      end
    end
  end
end
