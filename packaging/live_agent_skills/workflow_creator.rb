# frozen_string_literal: true

require "digest"
require_relative "workflow_creator_text_safety"

module HiveLiveAgentProof
  module WorkflowCreator
    class Error < StandardError; end

    request = "Create a three-stage editorial workflow that researches, drafts, " \
              "and requires approval before publishing."
    prompt = <<~PROMPT
      /hive
      #{request}
      Use the installed Hive workflow-creator capability in this initialized project.
      This is creation-only: validate the result, report the defaults, and do not create or run a task.
    PROMPT
    task_request = "Research and draft the launch announcement for approval."
    task_key = "workflow-creator-proof:editorial:live-proof"
    task_slug = "editorial-live-proof"
    command_labels = %w[
      candidate-version candidate-workflow-list candidate-workflow-new candidate-workflow-validate
      candidate-workflow-commit candidate-task-create candidate-task-run candidate-task-retry
      candidate-operational-status
    ]
    task_prompt = <<~PROMPT
      /hive
      Use the validated editorial workflow to create and run one task for:
      "#{task_request}"
      Use idempotency key #{task_key}. In this exact order: create the task,
      run its first stage once, repeat the same creation command once to prove the retry is a no-op,
      then query operational status. Do not publish or perform any other external action.
    PROMPT
    task_argv = [
      "new", "workflow-creator-proof", "--workflow", "editorial", "--idempotency-key", task_key,
      "--json", task_request
    ]
    files = %w[
      .hive-state/workflows/editorial.yml .hive-state/workflows/editorial/draft.md
      .hive-state/workflows/editorial/research.md
    ]
    Vocabulary = Values.capture(
      "schema_version" => 1,
      "evidence_schema" => "hive-live-workflow-creator-evidence",
      "installed_schema" => "hive-live-workflow-creator-installed-manifest",
      "execution_schema" => "hive-live-workflow-creator-execution-receipt",
      "execution_plan" => "hive-live-workflow-creator-execution-plan/v1",
      "scanner" => "hive-live-agent-proof/v1",
      "request" => request, "prompt" => prompt, "task_request" => task_request,
      "task_key" => task_key, "task_slug" => task_slug, "task_prompt" => task_prompt,
      "task_new_argv" => task_argv,
      "command_labels" => command_labels,
      "commands" => [
        [ "version" ], [ "workflow", "list", "--json" ], [ "workflow", "new", "editorial", "--json" ],
        [ "workflow", "validate", "editorial", "--json" ], [ "workflow", "commit", "editorial" ], task_argv,
        [ "run", "{created_slug}" ], task_argv, [ "status", "--operational", "--json" ]
      ],
      "task_slug_binding" => {
        "source_position" => 6, "source_result_field" => "slug", "target_position" => 7,
        "target_argument" => 1, "template" => "{created_slug}"
      },
      "files" => files, "executed_instruction" => files.fetch(2),
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
        "workflow" => "editorial", "first_created" => true,
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
    ).value
  end
end

require_relative "workflow_creator_contract"
require_relative "workflow_creator_execution_contract"

module HiveLiveAgentProof
  module WorkflowCreator
    private_constant :Contract, :ExecutionContract

    def self.commands_for(task_slug:)
      slug = capture(task_slug).value
      Contract.assert!(Contract::TASK_SLUG.match?(slug), "workflow-creator task slug is invalid")
      commands, binding = Vocabulary.values_at("commands", "task_slug_binding")
      resolved = commands.map(&:dup)
      target = resolved.fetch(binding.fetch("target_position") - 1)
      Contract.assert!(target.fetch(binding.fetch("target_argument")) == binding.fetch("template"),
                       "workflow-creator command template is invalid")
      target[binding.fetch("target_argument")] = slug
      Values.capture(resolved)
    rescue ArgumentError, IndexError, KeyError, NoMethodError, TypeError, Values::Error
      raise Error, "workflow-creator task slug is invalid"
    end
    def self.failure(...) = Contract.failure(...)
    def self.validate_nonpassing!(row, exact_secrets: []) =
      Contract.validate_nonpassing!(capture(row), capture(exact_secrets).value)
    def self.validate_primary!(row:, manifest:, candidate_sha:, bundle_records:) =
      Contract.validate_primary!(capture(row), capture(manifest), capture(candidate_sha), capture(bundle_records))
    def self.validate_installation!(document:, kind:, manifest:, candidate_sha:) =
      Contract.validate_installation!(capture(document), capture(kind), capture(manifest), capture(candidate_sha))
    def self.validate_execution!(receipt:, row:, candidate_sha:, manifest:, installation_records:,
                                 receipt_sha256:, candidate_installation:, openclaw_installation:) =
      ExecutionContract.validate!(capture(receipt), capture(row), capture(candidate_sha), capture(manifest),
                                  capture(installation_records), capture(receipt_sha256),
                                  capture(candidate_installation), capture(openclaw_installation))
    def self.capture(value)
      Values.capture(value)
    rescue Values::Error
      raise Error, "workflow-creator input cannot be captured"
    end
    private_class_method :capture
  end
end
