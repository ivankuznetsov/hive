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
      "hive-approve" => 1,
      "hive-findings" => 1,
      "hive-stage-action" => 1,
      "hive-metrics-rollback-rate" => 1
    }.freeze

    # Absolute path to the published JSON Schema files. Use
    # `Hive::Schemas.schema_path(name)` for a specific schema; external
    # consumers validate emitted documents with any draft-2020-12 validator.
    def self.schema_dir
      File.expand_path("../schemas", __dir__)
    end

    def self.schema_path(name)
      version = SCHEMA_VERSIONS.fetch(name)
      File.join(schema_dir, "#{name}.v#{version}.json")
    end

    # Build the JSON error envelope shared by every command that emits a
    # versioned schema. Centralised so the same Hive::Error subclass
    # surfaces with the same envelope shape regardless of which command
    # raised it. Per-error structured fields (candidates / id / path /
    # stage) are pulled off the exception when present.
    module ErrorEnvelope
      module_function

      def build(schema:, error:, error_kind:, extras: {})
        payload = {
          "schema" => schema,
          "schema_version" => SCHEMA_VERSIONS.fetch(schema),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind,
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        }.merge(extras)

        payload["candidates"] = error.candidates if error.is_a?(Hive::AmbiguousSlug)
        payload["id"] = error.id if error.is_a?(Hive::UnknownFinding)
        payload["path"] = error.path if error.is_a?(Hive::DestinationCollision)
        payload["stage"] = error.stage if error.is_a?(Hive::FinalStageReached)
        payload
      end
    end

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
      APPROVE       = "approve".freeze
      RUN           = "run".freeze
      RECOVER_STALE = "recover_stale".freeze
      NO_OP         = "no_op".freeze
      # Self-derived: every constant in this module other than ALL itself.
      # Defined last so the `constants` lookup runs after every value-bearing
      # constant is in place but before ALL is added.
      ALL = constants.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `tasks[].action` (and `tasks[].action_label` lookup
    # keys) emitted by `hive status --json`. Same self-derived ALL pattern
    # as NextActionKind so adding a new bucket without updating ALL is
    # impossible. Adding a new value is non-breaking by contract; renaming
    # or removing a value bumps SCHEMA_VERSIONS["hive-status"].
    module TaskActionKind
      READY_TO_BRAINSTORM = "ready_to_brainstorm".freeze
      READY_TO_PLAN       = "ready_to_plan".freeze
      READY_TO_DEVELOP    = "ready_to_develop".freeze
      READY_FOR_PR        = "ready_for_pr".freeze
      READY_TO_ARCHIVE    = "ready_to_archive".freeze
      NEEDS_INPUT         = "needs_input".freeze
      REVIEW_FINDINGS     = "review_findings".freeze
      RECOVER_EXECUTE     = "recover_execute".freeze
      AGENT_RUNNING       = "agent_running".freeze
      ARCHIVED            = "archived".freeze
      ERROR               = "error".freeze
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

  # Catch-all wrapper for unexpected non-Hive errors that escape into the
  # CLI's top-level rescue. Translates to SOFTWARE (70) so wrappers can
  # treat it like other internal failures rather than the generic 1.
  class InternalError < Error
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
    attr_reader :stage

    def initialize(message, stage:)
      super(message)
      @stage = stage
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
