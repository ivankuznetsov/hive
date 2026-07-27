require_relative "hive/version"
require_relative "hive/errors"

module Hive
  MIN_CLAUDE_VERSION = "2.1.118".freeze
  # Canonical GitHub org + repo. Referenced by the release probe
  # (UpdateCheck), the brew tap + installer URL (Commands::Update), etc.
  # One place to change on a repository rename.
  REPO_OWNER = "ivankuznetsov".freeze
  REPO_NAME = "hive".freeze

  module Schemas
    # JSON schema versions for the agent-callable contracts emitted by the
    # CLI. Bump a value here when an existing key's shape changes or is
    # removed; adding new keys is non-breaking and does NOT require a bump.
    # Single source of truth so the two emit sites can't drift.
    SCHEMA_VERSIONS = {
      "hive-status" => 7,
      "hive-operational-status" => 3,
      "hive-watch-event" => 1,
      "hive-act" => 2,
      "hive-init" => 2,
      "hive-init-preview" => 1,
      "hive-new" => 1,
      "hive-setup-agents" => 1,
      "hive-setup" => 1,
      "hive-web-status" => 1,
      "hive-web-install" => 1,
      "hive-capture-requirement" => 1,
      "hive-web-capture-runtime" => 1,
      "hive-artifact-capture" => 1,
      "hive-doctor" => 2,
      "hive-status-diagnose" => 2,
      "hive-run" => 2,
      "hive-approve" => 2,
      "hive-decide" => 1,
      "hive-findings" => 1,
      "hive-stage-action" => 2,
      "hive-metrics-rollback-rate" => 1,
      "hive-markers-clear" => 1,
      "hive-forget" => 1,
      "hive-drop" => 2,
      "hive-prune" => 1,
      "hive-daemon-status" => 1,
      "hive-daemon-stop" => 1,
      "hive-daemon-enroll" => 1,
      "hive-daemon-reload" => 1,
      "hive-daemon-install" => 1,
      # Read-only inspection of the daemon's dispatch-request queue
      # (`hive daemon queue [list|show|prune]`). See AN-1/2/3 and
      # `Hive::Commands::Daemon#queue_command`.
      "hive-daemon-queue" => 1,
      "hive-patrol" => 3,
      "hive-patrol-finding" => 3,
      "hive-refactor-patrol" => 3,
      "hive-refactor-patrol-jobs" => 1,
      "hive-refactor-patrol-thesis" => 3,
      # Scaffold a blank per-project workflow descriptor (`hive workflow new ID
      # --json`). The error arm routes through Hive::Schemas::ErrorEnvelope so
      # its output carries the same schema/schema_version/error_kind keys as
      # every other agent-callable command's error envelope; the success arm
      # builds its hash directly.
      "hive-workflow-new" => 1,
      # Read-only production-resolution validation for owner-authored,
      # managed, and built-in workflows (`hive workflow validate ID --json`).
      "hive-workflow-validate" => 1,
      "hive-workflow-install" => 2,
      # v2 gives selected managed rows their active immutable configuration
      # digest plus redacted per-slot mapping and optional-input discovery.
      "hive-workflow-list" => 2,
      "hive-workflow-remove" => 1,
      "hive-workflow-update" => 2,
      "hive-workflow-publish" => 2,
      "hive-module-lifecycle" => 1,
      "hive-module-list" => 1,
      "hive-module-event" => 1,
      "hive-module-decision" => 1,
      "hive-module-status" => 1,
      "hive-module-doctor" => 1,
      "hive-module-dry-run" => 1,
      "hive-module-migration" => 1,
      "hive-module-shadow-decision" => 1,
      "hive-module-migration-report" => 1,
      # Daily digest of tasks waiting on human input (`hive answer-digest
      # --json`). The success envelope reports the send outcome plus the full
      # waiting set (count/tasks); the Thor-usage error path emits the shared
      # error envelope via JSON_USAGE_ERROR_CONTRACTS, and a bad --date / status
      # outage emit the in-command error envelope.
      "hive-answer-digest" => 1,
      "hive-bot-status" => 1,
      "hive-bot-stop" => 1,
      "hive-bot-reload" => 1,
      "hive-bot-install" => 1,
      "hive-pairing-list" => 1,
      "hive-pairing-approve" => 1,
      # File-backed dispatch request the bot writes for the daemon to
      # consume. One JSON file per pending request under the state-home
      # `dispatch_requests/` directory. See
      # `Hive::Daemon::DispatchRequestQueue` and
      # `Hive::Bot::DispatchRequestWriter`.
      "hive-dispatch-request" => 4,
      # Reverse-direction notice the daemon writes for the bot to relay a
      # non-zero, bot-originated dispatch back to the originating Telegram
      # chat. See `Hive::Daemon::DispatchResultQueue` (ADV-1).
      "hive-dispatch-result" => 2,
      # Internal source-of-truth record for durable task-stage ownership.
      "hive-attempt" => 3,
      # Dedicated operator-confirmed task closure input/receipt. These are
      # task-local authorities, not agent-callable command envelopes.
      "hive-task-closure-input" => 1,
      "hive-task-closure" => 1,
      # Project-local daemon ledger for task-bound merged-PR reconciliation.
      "hive-pr-merge-reconciliation" => 1
    }.freeze

    # Closed enum of Diagnostic.generated_by values accepted by the
    # published status schemas. This is deliberately narrower than
    # AgentProfiles.registered_names because custom profiles are a
    # runtime extension point, while generated_by is a wire contract.
    DIAGNOSTIC_GENERATORS = %w[local claude codex pi grok].freeze

    # Absolute path to the published JSON Schema files. Use
    # `Hive::Schemas.schema_path(name)` for the current version of a
    # schema; external consumers validate emitted documents with any
    # draft-2020-12 validator. Pass an explicit `version:` to load an
    # older revision (e.g. for back-compat tests against pinned
    # consumers).
    def self.schema_dir
      File.expand_path("../schemas", __dir__)
    end

    def self.schema_path(name, version: nil)
      version ||= SCHEMA_VERSIONS.fetch(name)
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
        if error.is_a?(Hive::WrongStage)
          payload["current_stage"] = error.current_stage if error.current_stage
          payload["target_stage"] = error.target_stage if error.target_stage
        end
        if error.is_a?(Hive::ConditionGateBlocked)
          payload["condition_gate"] = error.condition_gate
          payload["next_action"] = error.next_action
        end
        if error.is_a?(Hive::ConcurrentRunError)
          payload["holder"] = error.holder if error.holder
          payload["lock_path"] = error.lock_path if error.lock_path
        end
        if error.is_a?(Hive::DependencyWaitError) || error.is_a?(Hive::DependencyAdmissionError)
          payload["reason_code"] = error.reason_code
          payload["offending_ref"] = error.offending_ref
          payload["safe_correction"] = error.safe_correction
        end
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
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `tasks[].action` (and `tasks[].action_label` lookup
    # keys) emitted by `hive status --json`. Same self-derived ALL pattern
    # as NextActionKind so adding a new bucket without updating ALL is
    # impossible. Adding a new value is non-breaking by contract; renaming
    # or removing a value bumps SCHEMA_VERSIONS["hive-status"] — the one
    # pre-1.0 carve-out is documented in ADR-028 (wiki/decisions.md),
    # which permits in-place schema edits while hive has no external
    # consumers. Once hive ships, the strict bump rule applies.
    module TaskActionKind
      READY_TO_BRAINSTORM = "ready_to_brainstorm".freeze
      READY_TO_PLAN       = "ready_to_plan".freeze
      READY_TO_DEVELOP    = "ready_to_develop".freeze
      READY_TO_OPEN_PR    = "ready_to_open_pr".freeze
      READY_FOR_REVIEW    = "ready_for_review".freeze
      READY_TO_ARTIFACTS  = "ready_to_artifacts".freeze
      READY_TO_FINALIZE   = "ready_to_finalize".freeze
      READY_TO_ARCHIVE    = "ready_to_archive".freeze
      READY_TO_ADVANCE    = "ready_to_advance".freeze
      READY_TO_RUN        = "ready_to_run".freeze
      # Explicit operator-only retry for a validated draft-PR handoff. The
      # daemon's Policy does not dispatch this key; status still exposes the
      # exact `hive run` command for a human-controlled retry.
      RECOVER_DRAFT_PR    = "recover_draft_pr".freeze
      # A clean ad-hoc PR review that has completed: it stays PARKED at
      # 6-review rather than advancing to 7-artifacts. Deliberately NOT in
      # Daemon::Policy::ADVANCE_ACTIONS, so a daemon-enrolled project never
      # auto-dispatches `hive artifacts` to finalize someone else's PR.
      REVIEW_PARKED       = "review_parked".freeze
      NEEDS_INPUT         = "needs_input".freeze
      RECOVER_EXECUTE     = "recover_execute".freeze
      RECOVER_REVIEW      = "recover_review".freeze
      AGENT_RUNNING       = "agent_running".freeze
      ARCHIVED            = "archived".freeze
      MANUAL_STEERING     = "manual_steering".freeze
      ERROR               = "error".freeze
      ADMISSION_ERROR     = "admission_error".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `error_kind` values emitted by `hive run --json` when
    # an error envelope is produced. Each value maps 1:1 to a Hive::Error
    # subclass via Hive::Commands::Run#error_kind_for. `ALL` is self-derived
    # so adding a new constant without updating ALL is impossible.
    #
    # Adding a new kind is non-breaking by contract; renaming or removing a
    # value bumps SCHEMA_VERSIONS["hive-run"].
    module RunErrorKind
      CONCURRENT_RUN    = "concurrent_run".freeze
      TASK_IN_ERROR     = "task_in_error".freeze
      WRONG_STAGE       = "wrong_stage".freeze
      STAGE             = "stage".freeze
      CONFIG            = "config".freeze
      AGENT             = "agent".freeze
      GIT               = "git".freeze
      WORKTREE          = "worktree".freeze
      AMBIGUOUS_SLUG    = "ambiguous_slug".freeze
      INVALID_TASK_PATH = "invalid_task_path".freeze
      DEPENDENCY_WAIT    = "dependency_wait".freeze
      ADMISSION_ERROR    = "admission_error".freeze
      INTERNAL          = "internal".freeze
      ERROR             = "error".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `error_kind` values emitted by `hive status --json`
    # when an error envelope is produced. `hive status`'s producer surface
    # is much narrower than `hive run`'s — only ConfigError / InternalError
    # and the generic fallback. Same self-derived ALL pattern.
    module StatusErrorKind
      CONFIG   = "config".freeze
      INTERNAL = "internal".freeze
      ERROR    = "error".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    module OperationalActionErrorKind
      USAGE             = "usage".freeze
      STALE_OBSERVATION = "stale_observation".freeze
      AMBIGUOUS_TARGET  = "ambiguous_target".freeze
      CONCURRENT_RUN    = "concurrent_run".freeze
      DEPENDENCY_WAIT   = "dependency_wait".freeze
      ADMISSION_ERROR   = "admission_error".freeze
      CONFIG            = "config".freeze
      INTERNAL          = "internal".freeze
      ERROR             = "error".freeze
      ALL = constants(false).reject { |constant| constant == :ALL }.map { |constant| const_get(constant) }.freeze
    end

    # Closed enum of `error_kind` values emitted by `hive status --diagnose --json`.
    # Superset of StatusErrorKind — diagnose has additional retryable failure
    # modes (stale marker mid-spawn, concurrent diagnose in flight) that agent
    # callers branch on, plus slug-resolution errors surfaced through the
    # TaskResolver path. The schema (schemas/hive-status-diagnose.v1.json)
    # mirrors this enum.
    module StatusDiagnoseErrorKind
      CONFIG          = "config".freeze
      INTERNAL        = "internal".freeze
      ERROR           = "error".freeze
      STALE_MARKER    = "stale_marker".freeze
      IN_FLIGHT       = "in_flight".freeze
      SLUG_NOT_FOUND  = "slug_not_found".freeze
      AMBIGUOUS_SLUG  = "ambiguous_slug".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Mixin for command classes that emit a versioned JSON envelope
    # under `--json`. Centralises the `@stdout_written` guard, the
    # twin `Hive::Error` / `StandardError` rescue scaffold, and the
    # JSON-write+EPIPE-swallow boilerplate. Each consumer provides:
    #
    #   * `envelope_schema` — the schema name (e.g. "hive-forget")
    #   * `envelope_error_kind(error)` — map an exception to a
    #     closed-enum `error_kind` value
    #
    # Used by default-stdout command producers whose error schemas share
    # ErrorEnvelope's common shape. Commands with injected output streams,
    # variant schema routing, or schema-specific payloads keep specialised
    # emitters. Metrics, for example, deliberately retains its narrower v1
    # payload, which omits `error_class`; forcing it through this mixin would
    # change a published contract rather than remove duplication.
    #
    # Consumers may also override `envelope_extras` to merge per-command
    # fields (e.g. `{"verb" => "review"}`) into the envelope; the default is
    # no extras. `envelope_payload_for` preserves schema-specific field
    # allowlists, while `envelope_serialization_failure_policy` preserves each
    # producer's legacy warning, suppression, or re-raise behavior when an
    # error payload itself cannot be encoded.
    module EnvelopeEmitter
      def call_with_envelope
        @stdout_written = false
        yield
      rescue Hive::Error => e
        emit_envelope(e) if envelope_enabled? && !@stdout_written
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_envelope(wrapped) if envelope_enabled? && !@stdout_written
        raise wrapped
      end

      def emit_envelope(error)
        payload = envelope_payload_for(error)
        puts JSON.generate(payload)
        @stdout_written = true
      rescue Errno::EPIPE
        # stdout closed; the re-raise still carries the failure to bin/hive
        # for the exit code + stderr line. Nothing to surface.
        @stdout_written = true
      rescue JSON::GeneratorError => e
        case envelope_serialization_failure_policy
        when :raise
          raise
        when :warn
          warn "[hive] #{envelope_schema} error envelope was not serialisable: #{e.class}: #{e.message}"
        when :suppress
          nil
        else
          raise ArgumentError, "unknown envelope serialization failure policy: " \
                               "#{envelope_serialization_failure_policy.inspect}"
        end
        @stdout_written = true
      end

      def envelope_payload_for(error)
        Hive::Schemas::ErrorEnvelope.build(
          schema: envelope_schema,
          error: error,
          error_kind: envelope_error_kind(error),
          extras: envelope_extras_for(error)
        )
      end

      # Per-command fields merged into the error envelope. Override to add
      # e.g. `{"verb" => "review"}`; the default is no extras.
      def envelope_extras
        {}
      end

      # Composing commands may suppress their child-facing envelope while
      # still preserving typed exceptions for the outer command.
      def envelope_enabled?
        @json
      end

      # Most extras are command-scoped. Commands with error-specific fields
      # can override this hook without making the common emitter conditional.
      def envelope_extras_for(_error)
        envelope_extras
      end

      def envelope_serialization_failure_policy
        :warn
      end
    end

    # Closed enum of `error_kind` values emitted by `hive forget --json`.
    # `MISSING_NAME` is the missing-positional-argument case; `UNKNOWN_PROJECT`
    # is a typo against a real registry; both used to share `unknown_project`,
    # which collapsed two distinct failure modes for agent retry wrappers.
    # `CONFIG` covers malformed config.yml + missing $HIVE_HOME — surfaced
    # via Hive::ConfigError → exit 78. Same self-derived ALL pattern as the
    # other ErrorKind modules so a constant added without a schema-enum
    # update is caught by schema_files_test.
    module ForgetErrorKind
      USAGE           = "usage".freeze
      MISSING_NAME    = "missing_name".freeze
      UNKNOWN_PROJECT = "unknown_project".freeze
      CONFIG          = "config".freeze
      INTERNAL        = "internal".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `error_kind` values emitted by `hive drop --json`.
    # Drop is destructive but idempotent over partial cleanup: task
    # resolution errors remain USAGE, while cleanup infrastructure
    # failures surface as git/worktree/internal so operators know
    # whether anything remains to repair.
    module DropErrorKind
      ALREADY_ARCHIVED  = "already_archived".freeze
      AMBIGUOUS_SLUG    = "ambiguous_slug".freeze
      WRONG_STAGE       = "wrong_stage".freeze
      INVALID_TASK_PATH = "invalid_task_path".freeze
      CONFIG            = "config".freeze
      GIT               = "git".freeze
      WORKTREE          = "worktree".freeze
      INTERNAL          = "internal".freeze
      ERROR             = "error".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `error_kind` values emitted by `hive daemon enable`
    # / `hive daemon disable --json`. Each value maps 1:1 to a failure
    # mode in Hive::Commands::Daemon#set_enabled. Same self-derived ALL
    # pattern as the other ErrorKind modules.
    #
    #   missing_project   — PROJECT positional was missing/empty and
    #                       --all was not passed.
    #   unknown_project   — PROJECT does not match any registry entry.
    #   project_and_all   — both PROJECT and --all were passed; refuses
    #                       to silently apply --all.
    #   not_initialised   — PROJECT exists in the registry but its
    #                       <project>/.hive-state/config.yml is missing
    #                       (a partial init state).
    #   no_projects       — --all was passed but the registry is empty.
    #   config            — malformed config.yml (Psych::Exception or
    #                       non-mapping shape) → exit 78.
    #   internal          — uncategorised crash (exit 70).
    module EnrollErrorKind
      MISSING_PROJECT       = "missing_project".freeze
      UNKNOWN_PROJECT       = "unknown_project".freeze
      PROJECT_AND_ALL       = "project_and_all".freeze
      NOT_INITIALISED       = "not_initialised".freeze
      NO_PROJECTS           = "no_projects".freeze
      CONFIG                = "config".freeze
      INTERNAL              = "internal".freeze
      # Flag passed to a subcommand that doesn't accept it (e.g.,
      # `--force` on `hive daemon stop`). Distinct from PROJECT_AND_ALL
      # so automation branching on error_kind can act differently.
      WRONG_SUBCOMMAND_FLAG = "wrong_subcommand_flag".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `error_kind` values emitted by `hive prune --json`.
    # `USAGE` covers `--dry-run` flag-validation (currently unreachable; reserved
    # for future flag work so v1 can absorb it without a v2 bump). `CONFIG`
    # covers malformed config.yml + missing $HIVE_HOME via Hive::ConfigError.
    module PruneErrorKind
      USAGE    = "usage".freeze
      CONFIG   = "config".freeze
      INTERNAL = "internal".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
    end

    # Closed enum of `error_kind` values emitted by `hive workflow new --json`.
    # `usage` covers a missing/invalid/reserved id and an unknown subcommand
    # (exit 64). `concurrent_run` is the commit-lock contention case (exit 75,
    # retryable) — surfaced as JSON now instead of plain stderr. `config`/`git`
    # are config.yml / commit failures; `error` is the uncategorised fallback.
    module WorkflowNewErrorKind
      USAGE          = "usage".freeze
      CONFIG         = "config".freeze
      GIT            = "git".freeze
      CONCURRENT_RUN = "concurrent_run".freeze
      ERROR          = "error".freeze
      ALL = constants(false).reject { |c| c == :ALL }.map { |c| const_get(c) }.freeze
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

  autoload :DiagnosticEvidence, File.expand_path("hive/diagnostic_evidence.rb", __dir__)
  autoload :DiagnosticHelpers, File.expand_path("hive/diagnostic_helpers.rb", __dir__)
end
