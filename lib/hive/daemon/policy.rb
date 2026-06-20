require "hive/workflows"

module Hive
  module Daemon
    # Pure decision module: maps a `hive status --json` task row's
    # `action` field (a `Hive::Schemas::TaskActionKind` value) plus
    # state-file mtime and dependency context to one of these outcomes
    # (authoritative list: the `@return` tag on `decide` below):
    #
    #   :dispatch              — run `row.suggested_command` as a child
    #   :blocked_on_dependency — hold: an unmet/unresolved task dependency
    #                            (the `blocked` gate; takes precedence over
    #                            the Q&A hold)
    #   :poll_for_merge        — hand off to PrMergeWatcher (finalize → done)
    #   :wait_for_debounce     — user is mid-edit; let mtime settle
    #   :wait_for_answers      — brainstorm Q&A still has unanswered
    #                            questions; hold the resume until every
    #                            question is answered (Telegram answers land
    #                            one at a time)
    #   :record_baseline       — first-sight edit-resume row; seed the mtime
    #                            baseline without dispatching
    #   :skip                  — do nothing this tick
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
        ready_to_artifacts
        ready_to_finalize
        ready_to_advance
      ].freeze

      # `ready_to_run` is the generic-stage "run the agent" action. Unlike
      # the pure advance actions it is mtime-debounced against the last
      # dispatch, NOT fired unconditionally: a generic `kind: :agent` stage
      # whose agent exits 0 without writing a WAITING/COMPLETE marker leaves
      # the stage marker `:none`, which re-classifies as `ready_to_run` on
      # every tick. Treating it as a pure advance action would re-dispatch
      # `hive run` until the per-project daily cap drains and then halt all
      # dispatch (coding is immune — a markerless post-run coding stage
      # classifies as the debounced `needs_input`). First sight (no prior
      # dispatch) runs once; afterwards it only re-runs when the state file
      # mtime advances past the last dispatch (genuine new input), mirroring
      # the edit-resume brake.
      RUN_ACTION = "ready_to_run".freeze

      # Action that means "task is at the finalize stage, waiting for the human
      # to merge the PR on GitHub". Daemon hands off to PrMergeWatcher (U10)
      # which polls `gh pr view --json state` and dispatches `hive archive`
      # on `MERGED`.
      MERGE_WAIT_ACTION = "ready_to_archive".freeze

      # Actions that mean "the task is in a stage and ready to RE-RUN with
      # fresh user input from the state file". Detection is mtime-debounced
      # so a mid-save partial draft doesn't trigger an early dispatch.
      EDIT_RESUME_ACTIONS = %w[
        needs_input
      ].freeze

      # Decide what to do with one task row.
      #
      # @param action [String] the `tasks[].action` value from hive-status JSON
      # @param stage [String, nil] the `tasks[].stage` value (e.g. "3-plan") # coding-scoped: example dir only
      # @param workflow [String, nil] the `tasks[].workflow` value. Nil is
      #   treated as coding for backward-compatible test doubles and older
      #   status payloads.
      # @param command [String, nil] the `suggested_command` for the row (may be nil)
      # @param state_file_mtime [Time, nil] mtime of the task's state file
      # @param last_dispatched_state_file_mtime [Time, nil] mtime captured at the
      #   last successful dispatch on this (project, slug); nil = no prior dispatch
      # @param now [Time] current time (injected for testability)
      # @param edit_debounce_sec [Integer] minimum age of mtime before a
      #   `:edit`-class row is eligible for dispatch (default 30s)
      # @param answers_pending [Boolean] true when this is a brainstorm
      #   Q&A row that still has unanswered questions. The mtime-debounce
      #   resume CANNOT tell "answered 1 of 3, still going" from "done"
      #   (each Telegram answer bumps the file mtime), so a would-be
      #   `:dispatch` on an edit-resume row is held as `:wait_for_answers`
      #   while answers are pending. The first-sight `:record_baseline`
      #   and the `:skip`/`:wait_for_debounce` outcomes are unaffected, so
      #   the editor-bulk-save path still resumes once it is complete. The
      #   dispatcher computes this by parsing the brainstorm file.
      # @param blocked [Boolean] the status JSON's verbatim dependency-gate
      #   flag. When true, a would-be `:dispatch` is gated to
      #   `:blocked_on_dependency`, taking precedence over `answers_pending`
      #   (applied to both advance/plan-approval and edit-resume rows).
      #
      # @return [Symbol] one of :dispatch, :blocked_on_dependency,
      #   :poll_for_merge, :wait_for_debounce, :wait_for_answers,
      #   :record_baseline, :skip
      #
      # `:record_baseline` is the first-sight `kind: edit` outcome:
      # the dispatcher does NOT spawn a child, but it MUST call
      # ConcurrencyController#observe_state_file_mtime so the next tick
      # has a baseline to compare against.
      def decide(action:, stage: nil, workflow: nil, command:, state_file_mtime:, last_dispatched_state_file_mtime:,
                 now:, edit_debounce_sec: 30, answers_pending: false, blocked: false)
        return :skip if action.nil?
        # Three branches dispatch the row's command verbatim (advance,
        # plan_approval) or via the edit-resume path (edit_resume).
        # All three need nil/empty-command protection. The guard
        # lists plan_approval? explicitly even though today's
        # plan_approval? rows are always edit_resume? rows too
        # (`needs_input`); a future refactor extending plan_approval?
        # to a non-edit_resume action would otherwise silently lose
        # this coverage. PR #83 code review finding #3.
        if (advance?(action) || edit_resume?(action) || run?(action) ||
            plan_approval?(action, stage, workflow)) &&
           (command.nil? || command.empty?)
          return :skip
        end

        if advance?(action) || plan_approval?(action, stage, workflow)
          blocked ? :blocked_on_dependency : :dispatch
        elsif action == MERGE_WAIT_ACTION
          :poll_for_merge
        elsif run?(action)
          # Debounced generic-run dispatch (see RUN_ACTION). First sight
          # dispatches; a markerless re-classification (mtime unchanged
          # since last dispatch) is braked to `:skip` so the daemon does
          # not re-spawn `hive run` every tick. The dependency gate still
          # wins over a would-be dispatch.
          outcome = decide_run(state_file_mtime: state_file_mtime,
                               last_dispatched: last_dispatched_state_file_mtime,
                               now: now,
                               debounce_sec: edit_debounce_sec)
          (outcome == :dispatch && blocked) ? :blocked_on_dependency : outcome
        elsif edit_resume?(action)
          outcome = decide_edit(state_file_mtime: state_file_mtime,
                                last_dispatched: last_dispatched_state_file_mtime,
                                now: now,
                                debounce_sec: edit_debounce_sec)
          # Gate a would-be edit-resume `:dispatch` on two holds, in
          # precedence order: an unmet task dependency wins
          # (→ :blocked_on_dependency), then unanswered brainstorm Q&A
          # (→ :wait_for_answers). Both gate ONLY the terminal `:dispatch`
          # — the first-sight `:record_baseline` and the `:skip`/
          # `:wait_for_debounce` outcomes pass through unchanged, so the
          # mtime baseline is still seeded and the editor-bulk-save path
          # dispatches normally once every answer is in and the block
          # clears.
          if outcome == :dispatch && blocked
            :blocked_on_dependency
          elsif outcome == :dispatch && answers_pending
            :wait_for_answers
          else
            outcome
          end
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

      def run?(action)
        action == RUN_ACTION
      end

      # Literal `"3-plan"` equality matches every other stage-identity # coding-scoped: plan auto-approval is a coding workflow rule
      # check in the codebase (e.g., `bubble_model.rb:1738 when "3-plan"` # coding-scoped: historical coding TUI reference
      # and `Hive::Stages::DIRS` membership). Earlier drafts used
      # `/\A\d+-plan\z/` but the regex matched any digit-prefixed plan
      # stage; today's `Hive::Stages::DIRS` is a closed 9-entry enum
      # with exactly one plan stage, so the regex implied a forward-flex
      # that didn't exist and a hypothetical `1-plan`/`5-plan` would
      # silently inherit auto-approval. PR #83 code review finding #4
      # (cross-corroborated by reliability + testing + maintainability +
      # project-standards reviewers).
      def plan_approval?(action, stage, workflow)
        action == "needs_input" && coding_workflow?(workflow) && stage == "3-plan" # coding-scoped: daemon auto-approval only applies to coding plan pauses
      end

      def coding_workflow?(workflow)
        Hive::Workflows.coding_id?(workflow)
      end

      # Generic-stage run decision. First sight (no prior dispatch) runs the
      # stage once. After that, only re-dispatch when the operator has
      # touched the state file since the last dispatch (mtime advanced past
      # the recorded baseline, then settled past the debounce window) — so a
      # markerless agent run (marker stays `:none` → `ready_to_run` again)
      # cannot re-spawn `hive run` on every tick.
      def decide_run(state_file_mtime:, last_dispatched:, now:, debounce_sec:)
        return :dispatch if last_dispatched.nil?
        return :skip if state_file_mtime.nil?
        return :skip if state_file_mtime <= last_dispatched
        return :wait_for_debounce if (now - state_file_mtime) < debounce_sec

        :dispatch
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
