module Hive
  # Clean-loadable error boundary shared by component errors and the root
  # CLI aggregate. This file owns the exit-code contract and the entire
  # concrete error taxonomy; the lib/hive.rb root entrypoint only wires it
  # in via require_relative.
  module ExitCodes
    SUCCESS = 0
    GENERIC = 1
    ALREADY_INITIALIZED = 2
    TASK_IN_ERROR = 3
    WRONG_STAGE = 4
    USAGE = 64
    UNAVAILABLE = 69
    SOFTWARE = 70
    TEMPFAIL = 75
    CONFIG = 78
  end

  class Error < StandardError
    def exit_code
      ExitCodes::GENERIC
    end
  end

  class ConfigError < Error
    def exit_code
      ExitCodes::CONFIG
    end
  end

  # Process exit-code contract for the `hive` CLI.
  #
  # Codes are stable; agent callers can branch on them to decide retry vs
  # escalate vs propagate. The numeric values follow sysexits(3) where
  # plausible so wrappers and shells already understand them.
  #
  #   0   success
  #   1   generic failure (anything not classified below)
  #   2   already-initialized / idempotent reject (`hive init` on existing project)
  #   3   task is in :error marker state (a stage agent recorded an error)
  #   4   wrong stage (`hive run` on an inert 1-inbox folder, etc.)
  #   64  EX_USAGE — invalid argument: bad slug, malformed task path, …
  #   70  EX_SOFTWARE — internal error: git failure, worktree failure, agent failure, stage runner error
  #   75  EX_TEMPFAIL — retryable: lock contention (`ConcurrentRunError`)
  #   78  EX_CONFIG — bad project / global config
  #
  # Subclasses below override `exit_code` so any `raise Hive::SomeError` ->
  # `bin/hive` rescue path produces the right code automatically.
  class InvalidTaskPath < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  # Generic command-line usage failure. Unlike InvalidTaskPath, this does not
  # imply that a task identifier or filesystem path was malformed.
  class UsageError < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  class OperationalActionUsageError < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  class StaleOperationalObservation < Error
    def exit_code
      ExitCodes::TEMPFAIL
    end
  end

  class ConcurrentRunError < Error
    attr_reader :holder, :lock_path

    # `holder` carries the existing lock's metadata (pid, slug, stage,
    # started_at, process_start_time) when the collision was raised over a
    # live lock. May be nil when no holder context is available (e.g.,
    # commit-lock flock timeout, where flock doesn't expose the holder).
    # Surfaces in `hive run --json` ErrorPayload via Hive::Schemas::ErrorEnvelope
    # so agents can decide whether to wait, kill the holder, or escalate.
    def initialize(message, holder: nil, lock_path: nil)
      super(message)
      @holder = holder
      @lock_path = lock_path
    end

    def exit_code
      ExitCodes::TEMPFAIL
    end
  end

  class GitError < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  # Signals that `git rebase` halted with merge conflicts the caller is
  # expected to handle (typically by dispatching a conflict-resolution
  # agent or aborting). Distinct from the generic GitError so callers
  # can rescue conflicts without swallowing unrelated git failures.
  class RebaseConflict < GitError
  end

  class GhError < Error
  end

  class WorktreeError < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  class AgentError < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  # A trusted adapter transport failure ended the enclosing explicit-routed
  # attempt. The safe signal is already handed to the attempt supervisor;
  # only RecoveryCoordinator may decide when another attempt is admitted.
  class ProviderRouteFailed < AgentError
  end

  class TmuxError < AgentError
  end

  # A project config reached the shared loader with unsupported root keys.
  # Task/workflow discovery may recover from unreadable or otherwise invalid
  # config to preserve legacy task visibility, but this validation result must
  # reach every command unchanged instead of falling back to coding defaults.
  class UnsupportedProjectConfigError < ConfigError
  end

  # A dependency is valid but has not reached the depending project's gate.
  # This is retryable operational state, not a configuration error.
  class DependencyWaitError < Error
    attr_reader :reason_code, :offending_ref, :safe_correction

    def initialize(message, reason_code: "dependency_wait", offending_ref:, safe_correction:)
      super(message)
      @reason_code = reason_code
      @offending_ref = offending_ref
      @safe_correction = safe_correction
    end

    def exit_code
      ExitCodes::TEMPFAIL
    end
  end

  # A fail-closed dependency admission result. ConfigError ancestry gives
  # manual callers the stable, non-retryable CONFIG exit code.
  class DependencyAdmissionError < ConfigError
    attr_reader :reason_code, :offending_ref, :safe_correction

    def initialize(message, reason_code:, offending_ref:, safe_correction:)
      super(message)
      @reason_code = reason_code
      @offending_ref = offending_ref
      @safe_correction = safe_correction
    end
  end

  class UnavailableError < Error
    def exit_code
      ExitCodes::UNAVAILABLE
    end
  end

  class StageError < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  # Catch-all wrapper for unexpected non-Hive errors that escape into the
  # CLI's top-level rescue. Translates to SOFTWARE (70) so wrappers can
  # treat it like other internal failures rather than the generic 1.
  class InternalError < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  # A detached durable worker reached a non-zero terminal outcome without
  # emitting the JSON document its caller requested. Carry the worker's exact
  # exit status through the ordinary command envelope/rescue path.
  class AttemptExecutionError < Error
    attr_reader :attempt_id, :outcome

    def initialize(message, exit_code:, attempt_id:, outcome:)
      super(message)
      @attempt_exit_code = Integer(exit_code)
      @attempt_id = attempt_id.to_s
      @outcome = outcome.to_s
    end

    def exit_code
      @attempt_exit_code
    end
  end

  # `hive daemon install` outcome split (PR #113 follow-up): drift is a
  # recoverable USAGE error (re-run with --force) while a service-manager
  # failure (systemctl reload/restart, launchctl load) is SOFTWARE. Two
  # error classes so the top-level rescue maps each outcome to a stable
  # exit code (64 / 70) that automation can branch on without parsing
  # the JSON envelope.
  class DaemonInstallDriftError < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  class DaemonInstallFailed < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  # `hive bot install` mirrors the daemon's install outcome split: drift is
  # a recoverable USAGE error (re-run with --force) while a service-manager
  # failure (systemctl / launchctl) is SOFTWARE. Separate classes from the
  # daemon's so the top-level rescue maps each surface independently while
  # still producing the stable 64 / 70 exit codes automation branches on.
  class BotInstallDriftError < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  class BotInstallFailed < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  # `hive babysit install` uses the same drift-safe managed-service contract
  # as daemon and bot installation while keeping its CLI error identity
  # separate for stable exit-code handling.
  class BabysitterInstallDriftError < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  class BabysitterInstallFailed < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
  end

  # Raised by `hive run` when the stage's terminal marker is :error. The
  # runner itself succeeded — the agent recorded a task-level failure.
  # Distinct from StageError (which signals a runner bug / git failure).
  class TaskInErrorState < Error
    def exit_code
      ExitCodes::TASK_IN_ERROR
    end
  end

  # Raised when the user invokes `hive run` on an inert stage (1-inbox)
  # or invokes a verb (approve/develop/review/...) at the wrong stage.
  # Optional `current_stage:` / `target_stage:` carry the resolved stage
  # context so the JSON error envelope can surface them as structured
  # fields, distinct from the user-supplied `--stage` filter.
  class WrongStage < Error
    attr_reader :current_stage, :target_stage

    def initialize(message, current_stage: nil, target_stage: nil)
      super(message)
      @current_stage = current_stage
      @target_stage = target_stage
    end

    def exit_code
      ExitCodes::WRONG_STAGE
    end
  end

  # A forward transition rejected by condition authority. Carries the exact
  # gate and recovery action so JSON callers never need to parse WrongStage
  # prose or issue a second status request to decide what to do next.
  class ConditionGateBlocked < WrongStage
    attr_reader :condition_gate, :next_action

    def initialize(message, condition_gate:, next_action:, **stage_context)
      super(message, **stage_context)
      @condition_gate = condition_gate
      @next_action = next_action
    end
  end

  # Raised by `hive init` when the project is already initialized. The
  # operation is idempotent at the contract level — code 2 lets a caller
  # detect "already done" without retrying.
  class AlreadyInitialized < Error
    def exit_code
      ExitCodes::ALREADY_INITIALIZED
    end
  end

  # A slug resolved to folders in multiple registered projects, or in
  # multiple stages of one project. Carries the structured candidate list
  # so a JSON error envelope can surface it without re-parsing prose.
  # Inherits from InvalidTaskPath for the USAGE (64) exit code; the IS-A is
  # exit-code convenience, not a path-type relationship.
  class AmbiguousSlug < InvalidTaskPath
    attr_reader :slug, :candidates

    def initialize(message, slug:, candidates:)
      super(message)
      @slug = slug
      @candidates = candidates
    end
  end

  # The destination folder for a stage move already exists. Distinct class
  # so callers (and the JSON error envelope) can distinguish a real
  # collision from a generic error sharing exit code 1.
  class DestinationCollision < Error
    attr_reader :path

    def initialize(message, path:)
      super(message)
      @path = path
    end
  end

  # Forward auto-advance was asked but the task is at the final stage.
  # Maps to WRONG_STAGE (4) so wrappers can branch cleanly between
  # "real collision (1)" and "no further stage (4)".
  class FinalStageReached < WrongStage
    def initialize(message, stage:)
      super(message, current_stage: stage)
    end

    # Back-compat: callers (and the JSON error envelope) used `error.stage`.
    # current_stage is the canonical name on the parent; this preserves the
    # older read-side surface without forcing a wider rename.
    def stage
      current_stage
    end
  end

  # The task has no review file at the requested (or default-latest) pass
  # — `hive findings` / `accept-finding` / `reject-finding` only make sense
  # against an existing `reviews/ce-review-NN.md`.
  class NoReviewFile < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  # The TUI's log-tail mode opened on a slug whose `<state>/logs/<slug>/`
  # directory contains no `*.log` files yet. Common race between an
  # `agent_running` row appearing in the status snapshot and the agent
  # actually flushing its first byte to disk; the render-mode boundary
  # catches this and flashes a friendly message instead of entering an
  # empty viewer.
  class NoLogFiles < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  # An ID was passed to accept-finding / reject-finding that doesn't
  # match any finding in the targeted review file.
  class UnknownFinding < Error
    attr_reader :id

    def initialize(message, id: nil)
      super(message)
      @id = id
    end

    def exit_code
      ExitCodes::USAGE
    end
  end

  # accept-finding / reject-finding was invoked with no IDs, no --severity,
  # and no --all — there's nothing to act on. Distinct from
  # InvalidTaskPath (the path was valid; the *argument set* was empty) so
  # callers branching on `error_kind` get a clearer signal.
  class NoSelection < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  # A rollback attempt itself failed after a commit failure. Distinct
  # from a plain Hive::Error so the agent contract can differentiate:
  # a typed re-raise (commit failed but rollback succeeded → fs and git
  # are pristine; safe to retry) from this class (commit failed AND
  # rollback failed → fs/git may be inconsistent; manual intervention
  # required before retry).
  class RollbackFailed < Error
    def exit_code
      ExitCodes::GENERIC
    end
  end
end
