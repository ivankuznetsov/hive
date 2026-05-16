module Hive
  module Daemon
    # Pure decision module: maps a `hive status --json` task row's
    # `action` field (a `Hive::Schemas::TaskActionKind` value) plus
    # state-file mtime context to one of four outcomes:
    #
    #   :dispatch          — run `row.suggested_command` as a child
    #   :poll_for_merge    — hand off to PrMergeWatcher (7-finalize → 8-done)
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
    # The only non-marker-driven decisions are:
    # - plan approval rows (`3-plan` + `needs_input`) are auto-dispatched
    #   for daemon-enabled projects. The durable consent is enabling the
    #   daemon; a generated plan should not sit forever waiting for an
    #   editor open/close gesture.
    # - true edit waits dispatch only if the state-file mtime is strictly
    #   newer than the last observed mtime AND `now - mtime >=
    #   edit_debounce_sec` (so a partial mid-save draft doesn't trigger
    #   an early dispatch).
    #
    # First-sight policy on `kind: edit`: the daemon sees a `_WAITING`
    # task with no prior observation. We CANNOT distinguish "agent just
    # wrote the WAITING marker" from "user already answered hours ago",
    # so the safe choice is to skip + record the current mtime as the
    # baseline. The next genuine user edit (mtime > baseline) triggers
    # dispatch. Operators of dormant-task scenarios can `touch` the
    # state file to wake the daemon.
    #
    # Post-completion mtime refresh (handled by Dispatcher, not Policy):
    # after every child reaps, the controller's recorded mtime is
    # updated to the current state-file mtime. This way the agent's
    # own write of the next `_WAITING` marker doesn't look like a
    # user edit on the next tick.
    module Policy
      module_function

      # Actions that mean "the task is ready to advance to the next stage".
      # The daemon dispatches `row.suggested_command` (which is the
      # promote-or-run workflow verb produced by `Hive::TaskAction`).
      ADVANCE_ACTIONS = %w[
        ready_to_brainstorm
        ready_to_plan
        ready_to_develop
        ready_to_open_pr
        ready_for_review
        ready_to_finalize
      ].freeze

      # Action that means "task is at 7-finalize, waiting for the human to merge
      # the PR on GitHub". Daemon hands off to PrMergeWatcher (U10) which
      # polls `gh pr view --json state` and dispatches `hive archive` on
      # `MERGED`.
      MERGE_WAIT_ACTION = "ready_to_archive".freeze

      # Actions that mean "the task is in a stage and ready to RE-RUN with
      # fresh user input from the state file". Detection is mtime-debounced
      # so a mid-save partial draft doesn't trigger an early dispatch.
      #
      # `review_findings` is deliberately EXCLUDED (PR-40 review P2 #5):
      # `Hive::TaskAction` emits `hive findings <slug>` for that case,
      # which is a read-only listing command, not a workflow verb.
      # Auto-dispatching it would produce a no-op spawn. Treat it as
      # `:skip` (falls through to the default branch).
      EDIT_RESUME_ACTIONS = %w[
        needs_input
      ].freeze

      # Decide what to do with one task row.
      #
      # @param action [String] the `tasks[].action` value from hive-status JSON
      # @param stage [String, nil] the `tasks[].stage` value (e.g. "3-plan")
      # @param command [String, nil] the `suggested_command` for the row (may be nil)
      # @param state_file_mtime [Time, nil] mtime of the task's state file
      # @param last_dispatched_state_file_mtime [Time, nil] mtime captured at the
      #   last successful dispatch on this (project, slug); nil = no prior dispatch
      # @param now [Time] current time (injected for testability)
      # @param edit_debounce_sec [Integer] minimum age of mtime before a
      #   `:edit`-class row is eligible for dispatch (default 30s)
      #
      # @return [Symbol] one of :dispatch, :poll_for_merge, :wait_for_debounce,
      #   :record_baseline, :skip
      #
      # `:record_baseline` is the first-sight `kind: edit` outcome:
      # the dispatcher does NOT spawn a child, but it MUST call
      # ConcurrencyController#observe_state_file_mtime so the next tick
      # has a baseline to compare against.
      def decide(action:, stage: nil, command:, state_file_mtime:, last_dispatched_state_file_mtime:,
                 now:, edit_debounce_sec: 30)
        return :skip if action.nil?
        # Three branches dispatch the row's command verbatim (advance,
        # plan_approval) or via the edit-resume path (edit_resume).
        # All three need nil/empty-command protection. The guard
        # lists plan_approval? explicitly even though today's
        # plan_approval? rows are always edit_resume? rows too
        # (`needs_input`); a future refactor extending plan_approval?
        # to a non-edit_resume action would otherwise silently lose
        # this coverage. PR #83 code review finding #3.
        if (advance?(action) || edit_resume?(action) || plan_approval?(action, stage)) &&
           (command.nil? || command.empty?)
          return :skip
        end

        if advance?(action) || plan_approval?(action, stage)
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

      # Literal `"3-plan"` equality matches every other stage-identity
      # check in the codebase (e.g., `bubble_model.rb:1833 when "3-plan"`
      # and `Hive::Stages::DIRS` membership). Earlier drafts used
      # `/\A\d+-plan\z/` but the regex matched any digit-prefixed plan
      # stage; today's `Hive::Stages::DIRS` is a closed 8-entry enum
      # with exactly one plan stage, so the regex implied a forward-flex
      # that didn't exist and a hypothetical `1-plan`/`5-plan` would
      # silently inherit auto-approval. PR #83 code review finding #4
      # (cross-corroborated by reliability + testing + maintainability +
      # project-standards reviewers).
      def plan_approval?(action, stage)
        action == "needs_input" && stage == "3-plan"
      end

      def decide_edit(state_file_mtime:, last_dispatched:, now:, debounce_sec:)
        return :skip if state_file_mtime.nil?

        if last_dispatched.nil?
          # First sight of this `kind: edit` row. We can't distinguish
          # "agent just wrote the WAITING marker" from "user answered
          # hours ago", so we record the current mtime as the baseline
          # and skip. The dispatcher must observe this signal to seed
          # the controller; the next genuine user edit (mtime > baseline)
          # then triggers a dispatch on a subsequent tick.
          return :record_baseline
        end

        # Subsequent visits: only re-fire if the user has actually edited
        # the state file since our last observation. The Dispatcher
        # refreshes `last_dispatched_state_file_mtime` to the post-
        # completion mtime after each child exit — so the agent's own
        # write of a fresh `_WAITING` marker won't look like user input.
        return :skip if state_file_mtime <= last_dispatched

        return :wait_for_debounce if (now - state_file_mtime) < debounce_sec

        :dispatch
      end
    end
  end
end
