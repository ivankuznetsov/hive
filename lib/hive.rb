module Hive
  VERSION = "0.1.0".freeze
  MIN_CLAUDE_VERSION = "2.1.118".freeze

  module Schemas
    # JSON schema versions for the agent-callable contracts emitted by the
    # CLI. Bump a value here when an existing key's shape changes or is
    # removed; adding new keys is non-breaking and does NOT require a bump.
    # Single source of truth so the two emit sites can't drift.
    SCHEMA_VERSIONS = {
      "hive-status" => 1,
      "hive-run" => 1,
      "hive-approve" => 1
    }.freeze

    # Closed enum of `next_action.kind` values emitted by `hive run --json`.
    # `ALL` is self-derived from the constants in this module so adding a
    # new kind without updating ALL is impossible.
    #
    # Adding a new kind is non-breaking by contract: callers MUST treat
    # unknown kinds as forward-compatible no-ops. Renaming or removing a
    # value requires a SCHEMA_VERSIONS["hive-run"] bump.
    module NextActionKind
      EDIT          = "edit".freeze
      MV            = "mv".freeze
      RECOVER_STALE = "recover_stale".freeze
      NO_OP         = "no_op".freeze
      # Self-derived: every constant in this module other than ALL itself.
      # Defined last so the `constants` lookup runs after every value-bearing
      # constant is in place but before ALL is added.
      ALL = constants.map { |c| const_get(c) }.freeze
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
  module ExitCodes
    SUCCESS = 0
    GENERIC = 1
    ALREADY_INITIALIZED = 2
    TASK_IN_ERROR = 3
    WRONG_STAGE = 4
    USAGE = 64
    SOFTWARE = 70
    TEMPFAIL = 75
    CONFIG = 78
  end

  class Error < StandardError
    def exit_code
      ExitCodes::GENERIC
    end
  end

  class InvalidTaskPath < Error
    def exit_code
      ExitCodes::USAGE
    end
  end

  class ConcurrentRunError < Error
    def exit_code
      ExitCodes::TEMPFAIL
    end
  end

  class GitError < Error
    def exit_code
      ExitCodes::SOFTWARE
    end
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

  class ConfigError < Error
    def exit_code
      ExitCodes::CONFIG
    end
  end

  class StageError < Error
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

  # Raised when the user invokes `hive run` on an inert stage (1-inbox).
  # The folder is in the wrong location for the requested operation.
  class WrongStage < Error
    def exit_code
      ExitCodes::WRONG_STAGE
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
end
