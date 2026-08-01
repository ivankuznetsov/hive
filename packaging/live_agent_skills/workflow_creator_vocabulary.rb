# frozen_string_literal: true

require_relative "proof_primitives"

module HiveLiveAgentProof
  WORKFLOW_CREATOR_REQUEST =
    "Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing.".freeze
  WORKFLOW_CREATOR_PROMPT = <<~PROMPT.freeze
    /hive
    #{WORKFLOW_CREATOR_REQUEST}
    Use the installed Hive workflow-creator capability in this initialized project.
    This is creation-only: validate the result, report the defaults, and do not create or run a task.
  PROMPT
  WORKFLOW_CREATOR_TASK_REQUEST =
    "Research and draft the launch announcement for approval.".freeze
  WORKFLOW_CREATOR_TASK_KEY =
    "workflow-creator-proof:editorial:live-proof".freeze
  WORKFLOW_CREATOR_TASK_SLUG = "editorial-live-proof".freeze
  WORKFLOW_CREATOR_TASK_PROMPT = <<~PROMPT.freeze
    /hive
    Use the validated editorial workflow to create and run one task for:
    "#{WORKFLOW_CREATOR_TASK_REQUEST}"
    Use idempotency key #{WORKFLOW_CREATOR_TASK_KEY}. In this exact order: create the task,
    run its first stage once, repeat the same creation command once to prove the retry is a no-op,
    then query operational status. Do not publish or perform any other external action.
  PROMPT
  WORKFLOW_CREATOR_TASK_NEW_ARGV = [
    "new", "workflow-creator-proof", "--workflow", "editorial",
    "--idempotency-key", WORKFLOW_CREATOR_TASK_KEY, "--json",
    WORKFLOW_CREATOR_TASK_REQUEST
  ].freeze
  WORKFLOW_CREATOR_COMMANDS = [
    [ "version" ],
    [ "workflow", "list", "--json" ],
    [ "workflow", "new", "editorial", "--json" ],
    [ "workflow", "validate", "editorial", "--json" ],
    [ "workflow", "commit", "editorial" ],
    WORKFLOW_CREATOR_TASK_NEW_ARGV,
    [ "run", WORKFLOW_CREATOR_TASK_SLUG ],
    WORKFLOW_CREATOR_TASK_NEW_ARGV,
    [ "status", "--operational", "--json" ]
  ].each(&:freeze).freeze
  WORKFLOW_CREATOR_FILES = [
    ".hive-state/workflows/editorial.yml",
    ".hive-state/workflows/editorial/draft.md",
    ".hive-state/workflows/editorial/research.md"
  ].freeze
  WORKFLOW_CREATOR_EXECUTED_INSTRUCTION =
    ".hive-state/workflows/editorial/research.md".freeze
  WORKFLOW_CREATOR_SCANNER = "hive-live-agent-proof/v1".freeze
  WORKFLOW_CREATOR_EXECUTION_RECEIPT_SCHEMA =
    "hive-live-workflow-creator-execution-receipt".freeze
  WORKFLOW_CREATOR_EXECUTION_PLAN =
    "hive-live-workflow-creator-execution-plan/v1".freeze
  WORKFLOW_CREATOR_OUTER_PROCESS_ROLES = [
    "workflow-creation-model-loop",
    "authorized-work-model-loop"
  ].freeze
  WORKFLOW_CREATOR_CLEANUP_TARGET_LABELS = [ "proof-workspace" ].freeze
  WORKFLOW_CREATOR_CONTAINMENT_MECHANISMS =
    [ "supervised-process-tree" ].freeze
  WORKFLOW_CREATOR_ROOT_LOSS_BEHAVIORS = [ "fail-closed" ].freeze
end
