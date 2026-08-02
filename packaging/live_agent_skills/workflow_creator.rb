require "digest"
require_relative "proof_primitives"
module HiveLiveAgentProof
  module WorkflowCreator
    request = "Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing."
    prompt = <<~PROMPT
      /hive
      #{request}
      Use the installed Hive workflow-creator capability in this initialized project.
      This is creation-only: validate the result, report the defaults, and do not create or run a task.
    PROMPT
    task_request = "Research and draft the launch announcement for approval."
    task_key = "workflow-creator-proof:editorial:live-proof"
    task_slug = "editorial-live-proof"
    task_prompt = <<~PROMPT
      /hive
      Use the validated editorial workflow to create and run one task for:
      "#{task_request}"
      Use idempotency key #{task_key}. In this exact order: create the task,
      run its first stage once, repeat the same creation command once to prove the retry is a no-op,
      then query operational status. Do not publish or perform any other external action.
    PROMPT
    task_argv = [
      "new", "workflow-creator-proof", "--workflow", "editorial",
      "--idempotency-key", task_key, "--json", task_request
    ]
    files = %w[
      .hive-state/workflows/editorial.yml
      .hive-state/workflows/editorial/draft.md
      .hive-state/workflows/editorial/research.md
    ]
    Vocabulary = Primitives.deep_freeze(
      "schema_version" => 1,
      "evidence_schema" => "hive-live-workflow-creator-evidence",
      "installed_schema" => "hive-live-workflow-creator-installed-manifest",
      "execution_schema" => "hive-live-workflow-creator-execution-receipt",
      "execution_plan" => "hive-live-workflow-creator-execution-plan/v1",
      "scanner" => "hive-live-agent-proof/v1",
      "request" => request,
      "prompt" => prompt,
      "task_request" => task_request,
      "task_key" => task_key,
      "task_slug" => task_slug,
      "task_prompt" => task_prompt,
      "task_new_argv" => task_argv,
      "commands" => [
        [ "version" ], [ "workflow", "list", "--json" ],
        [ "workflow", "new", "editorial", "--json" ],
        [ "workflow", "validate", "editorial", "--json" ],
        [ "workflow", "commit", "editorial" ], task_argv,
        [ "run", task_slug ], task_argv,
        [ "status", "--operational", "--json" ]
      ],
      "files" => files,
      "executed_instruction" => files.fetch(2),
      "native_activation" => { "kind" => "openclaw-skills-info", "invocation" => "/hive" },
      "graph" => {
        "valid" => true, "stages" => %w[research draft approval],
        "automatic_edges" => [ %w[research draft], %w[draft approval] ],
        "human_outcomes" => [
          { "stage" => "approval", "name" => "approve", "complete" => true,
            "artifact" => "draft.md", "to" => nil },
          { "stage" => "approval", "name" => "reject", "complete" => false,
            "artifact" => nil, "to" => "draft" }
        ]
      },
      "task" => {
        "slug" => task_slug, "workflow" => "editorial", "first_created" => true,
        "retry_created" => false, "run_count" => 1, "current_stage" => "1-research"
      },
      "classification" => { "execution_kind" => "authenticated_openclaw", "model_loop" => "executed" },
      "bundle_files" => %w[
        openclaw-workflow-creator.json candidate-installed-manifest.json
        openclaw-installed-manifest.json execution-receipt.json
      ],
      "member_roles" => {
        "candidate" => %w[audit_gateway executable interpreter_or_launcher lock package],
        "openclaw" => %w[executable interpreter_or_launcher lock package]
      },
      "outer_roles" => [
        { "role" => "workflow-creation-model-loop", "prompt_sha256" => Digest::SHA256.hexdigest(prompt) },
        { "role" => "authorized-work-model-loop", "prompt_sha256" => Digest::SHA256.hexdigest(task_prompt) }
      ],
      "archive_labels" => %w[candidate-package openclaw-package],
      "archive_policy_sha256" => Digest::SHA256.hexdigest("hive-live-workflow-creator-archive-policy/v1"),
      "cleanup_labels" => %w[proof-workspace]
    )
  end
end
require_relative "workflow_creator_contract"
require_relative "workflow_creator_execution_contract"

module HiveLiveAgentProof
  module WorkflowCreator
    private_constant :Primitives, :Contract, :ExecutionContract

    def self.canonical_json(value) = Primitives.canonical_json(value)
    def self.failure(...) = Contract.failure(...)
    def self.validate_nonpassing!(row) = Contract.validate_nonpassing!(row)
    def self.validate_primary!(row:, manifest:, candidate_sha:, bundle_records:) =
      Contract.validate_primary!(row:, manifest:, candidate_sha:, bundle_records:)
    def self.validate_installation!(document:, kind:, manifest:, candidate_sha:) =
      Contract.validate_installation!(document:, kind:, manifest:, candidate_sha:)
    def self.validate_execution!(receipt:, row:, candidate_sha:, manifest:, installation_records:,
                                 receipt_sha256:, candidate_installation:, openclaw_installation:) =
      ExecutionContract.validate!(receipt:, row:, candidate_sha:, manifest:, installation_records:,
                                  receipt_sha256:, candidate_installation:, openclaw_installation:)
  end
end
