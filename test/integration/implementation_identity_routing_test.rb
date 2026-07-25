require "test_helper"
require "hive/attempts/context"
require "hive/attempts/store"
require "hive/commands/status"
require "hive/implementation_identity/resolver"
require "hive/implementation_identity/store"
require "hive/task_projection/store"

class ImplementationIdentityRoutingTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:folder, :state_file, :slug, :id, :project_root, keyword_init: true)

  def test_codex_lifecycle_routes_and_reports_the_same_journaled_identity
    with_identity_task do |task, attempts|
      cfg = identity_config(task.project_root, provider: "codex", model: "gpt-5.6-sol", effort: "low")
      execute = capture_execute(task, attempts, cfg, generation: 1)
      open_pr = resolve_stage(task, attempts, cfg, "open_pr", "5-open-pr", generation: 1)
      review_fix = resolve_stage(task, attempts, cfg, "review.fix", "6-review", generation: 1)
      review_ci = resolve_stage(task, attempts, cfg, "review.ci", "6-review", generation: 1)

      assert_equal "low", execute.effective_effort
      assert_equal [ "--model", "gpt-5.6-terra", "-c", "model_reasoning_effort=medium" ],
                   open_pr.native_arguments
      [ review_fix, review_ci ].each do |selection|
        assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high" ],
                     selection.native_arguments
      end

      projection = Hive::TaskProjection::Store.new(
        task_folder: task.folder, attempt_store: attempts
      ).read
      journal_path = File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
      journal_before = File.binread(journal_path)
      command = Hive::Commands::Status.new
      first = command.implementation_identity_status(projection["implementation_identity"], cfg)
      second = command.implementation_identity_status(projection["implementation_identity"], cfg)

      assert_equal first, second
      assert_equal journal_before, File.binread(journal_path), "status previews must not append events"
      assert_equal "resolved", first.dig("stages", "open_pr", "status")
      assert_equal "persisted_execute", first.dig("stages", "review.fix", "source")
      assert_equal "gpt-5.6-sol", first.dig("stages", "review.ci", "model")
    end
  end

  def test_config_drift_reuses_generation_and_fenced_input_change_creates_new_owner
    with_identity_task do |task, attempts|
      codex_cfg = identity_config(task.project_root, provider: "codex", model: "gpt-5.6-sol")
      first = capture_execute(task, attempts, codex_cfg, generation: 1)
      claude_cfg = identity_config(task.project_root, provider: "claude", model: "claude-opus-4-6")

      drifted = capture_execute(task, attempts, claude_cfg, generation: 1, attempt_id: "execute-retry")
      assert_equal first.to_h, drifted.to_h

      File.write(File.join(task.folder, "plan.md"), "# accepted replacement plan\n")
      second = capture_execute(task, attempts, claude_cfg, generation: 2, attempt_id: "execute-generation-2")
      projection = Hive::TaskProjection::Store.new(
        task_folder: task.folder, attempt_store: attempts
      ).read
      identity = projection["implementation_identity"]

      assert_equal "claude", second.provider
      assert_equal "claude-opus-4-6", second.model
      assert_equal [ 1, 2 ], identity["history"].map { |entry| entry["generation"] }
      assert_equal "codex", identity.dig("history", 0, "provider")
      assert_equal "claude", identity.dig("execute", "provider")
    end
  end

  def test_every_implementation_identity_freezes_routing_until_a_new_generation
    with_identity_task do |task, attempts|
      first_cfg = identity_config(
        task.project_root,
        provider: "codex",
        model: "gpt-5.6-base-one",
        models: {
          "execute" => { "effort" => "low" },
          "execute_implementation" => { "model" => "gpt-5.6-execute-one" },
          "open_pr" => { "model" => "gpt-5.6-open-one", "effort" => "medium" },
          "review" => { "effort" => "high" },
          "review_fix" => { "model" => "gpt-5.6-fix-one" },
          "review_ci" => { "model" => "gpt-5.6-ci-one" }
        }
      )
      first = {
        "execute" => capture_execute(task, attempts, first_cfg, generation: 1),
        "open_pr" => resolve_stage(
          task, attempts, first_cfg, "open_pr", "5-open-pr", generation: 1,
          attempt_id: "open-pr-first"
        ),
        "review.fix" => resolve_stage(
          task, attempts, first_cfg, "review.fix", "6-review", generation: 1,
          attempt_id: "review-fix-first"
        ),
        "review.ci" => resolve_stage(
          task, attempts, first_cfg, "review.ci", "6-review", generation: 1,
          attempt_id: "review-ci-first"
        )
      }
      drifted_cfg = identity_config(
        task.project_root,
        provider: "codex",
        model: "gpt-5.6-base-drift",
        models: {
          "execute_implementation" => {
            "model" => "gpt-5.6-execute-drift", "effort" => "xhigh"
          },
          "open_pr" => { "model" => "gpt-5.6-open-drift", "effort" => "xhigh" },
          "review_fix" => { "model" => "gpt-5.6-fix-drift", "effort" => "xhigh" },
          "review_ci" => { "model" => "gpt-5.6-ci-drift", "effort" => "xhigh" }
        }
      )
      retried = {
        "execute" => capture_execute(
          task, attempts, drifted_cfg, generation: 1, attempt_id: "execute-retry"
        ),
        "open_pr" => resolve_stage(
          task, attempts, drifted_cfg, "open_pr", "5-open-pr", generation: 1,
          attempt_id: "open-pr-retry"
        ),
        "review.fix" => resolve_stage(
          task, attempts, drifted_cfg, "review.fix", "6-review", generation: 1,
          attempt_id: "review-fix-retry"
        ),
        "review.ci" => resolve_stage(
          task, attempts, drifted_cfg, "review.ci", "6-review", generation: 1,
          attempt_id: "review-ci-retry"
        )
      }

      assert_equal first.transform_values(&:to_h), retried.transform_values(&:to_h)
      assert_equal(
        {
          "execute" => [ "gpt-5.6-execute-one", "low" ],
          "open_pr" => [ "gpt-5.6-open-one", "medium" ],
          "review.fix" => [ "gpt-5.6-fix-one", "high" ],
          "review.ci" => [ "gpt-5.6-ci-one", "high" ]
        },
        first.transform_values { |selection| [ selection.model, selection.requested_effort ] }
      )

      File.write(File.join(task.folder, "plan.md"), "# accepted generation two plan\n")
      second = {
        "execute" => capture_execute(
          task, attempts, drifted_cfg, generation: 2, attempt_id: "execute-generation-2"
        ),
        "open_pr" => resolve_stage(
          task, attempts, drifted_cfg, "open_pr", "5-open-pr", generation: 2,
          attempt_id: "open-pr-generation-2"
        ),
        "review.fix" => resolve_stage(
          task, attempts, drifted_cfg, "review.fix", "6-review", generation: 2,
          attempt_id: "review-fix-generation-2"
        ),
        "review.ci" => resolve_stage(
          task, attempts, drifted_cfg, "review.ci", "6-review", generation: 2,
          attempt_id: "review-ci-generation-2"
        )
      }

      assert_equal(
        {
          "execute" => [ "gpt-5.6-execute-drift", "xhigh" ],
          "open_pr" => [ "gpt-5.6-open-drift", "xhigh" ],
          "review.fix" => [ "gpt-5.6-fix-drift", "xhigh" ],
          "review.ci" => [ "gpt-5.6-ci-drift", "xhigh" ]
        },
        second.transform_values { |selection| [ selection.model, selection.requested_effort ] }
      )
      events = Hive::TaskProjection.read_journal(
        File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
      )
      assert_equal 2, events.count { |event| event["event_type"] == "implementation_identity_captured" }
      assert_equal 6, events.count { |event| event["event_type"] == "implementation_stage_resolved" }
    end
  end

  def test_pi_and_grok_open_pr_keep_provider_default_unpinned_and_report_unsupported_effort
    with_tmp_dir do |project_root|
      FileUtils.mkdir_p(File.join(project_root, ".pi"))
      File.write(File.join(project_root, ".pi", "settings.json"),
                 JSON.generate("provider" => "anthropic", "model" => "claude-sonnet-4"))
      FileUtils.mkdir_p(File.join(project_root, ".grok"))
      File.write(File.join(project_root, ".grok", "settings.json"),
                 JSON.generate("model" => "grok-4.5"))

      { "pi" => "anthropic/claude-sonnet-4", "grok" => "grok-4.5" }.each do |provider, model|
        cfg = identity_config(project_root, provider: provider, model: model)
        resolver = Hive::ImplementationIdentity::Resolver.new(cfg: cfg)
        execute = resolver.resolve_execute(generation: 1, attempt_id: "#{provider}-execute")
        open_pr = resolver.resolve_stage("open_pr", execute_identity: execute)

        assert_equal provider, open_pr.provider
        assert_equal model, open_pr.model
        assert_equal false, open_pr.model_pinned
        assert_equal [], open_pr.native_arguments
        assert_equal "medium", open_pr.requested_effort
        assert_equal false, open_pr.effort_supported
        assert_nil open_pr.effective_effort
      end
    end
  end

  private

  def with_identity_task
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = TaskStub.new(
        folder: folder, state_file: File.join(folder, "task.md"), slug: "routing-task",
        id: 11534, project_root: root
      )
      File.write(task.state_file, "<!-- EXECUTE_WAITING -->\n")
      File.write(File.join(folder, "plan.md"), "# accepted plan\n")
      attempts = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      yield task, attempts
    end
  end

  def capture_execute(task, attempts, cfg, generation:, attempt_id: "execute-generation-1")
    attempt = create_attempt(
      task, attempts, attempt_id: attempt_id, stage: "4-execute", generation: generation,
      provider: cfg.dig("execute", "agent")
    )
    with_attempt(attempt, generation) do
      Hive::ImplementationIdentity::Store.new(
        task: task, cfg: cfg, attempt_store: attempts
      ).capture_execute!
    end
  end

  def resolve_stage(task, attempts, cfg, stage, intended_stage, generation:,
                    attempt_id: "#{stage.tr('.', '-')}-#{generation}")
    attempt = create_attempt(
      task, attempts, attempt_id: attempt_id, stage: intended_stage,
      generation: generation, provider: cfg.dig("execute", "agent")
    )
    with_attempt(attempt, generation) do
      Hive::ImplementationIdentity::Store.new(
        task: task, cfg: cfg, attempt_store: attempts
      ).resolve_stage!(stage)
    end
  end

  def create_attempt(task, attempts, attempt_id:, stage:, generation:, provider:)
    attempts.create_launching(
      attempt_id: attempt_id, request_id: "request-#{attempt_id}", predecessor_attempt_id: nil,
      task_id: task.id.to_s, project: "demo", task_slug: task.slug, intended_stage: stage,
      task_generation: "owner-#{generation}", ownership_generation: "owner-#{generation}",
      task_input_epoch: generation, progress_token: "progress-#{attempt_id}", provider: provider,
      starting_revision: nil, retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30,
      worker_argv: [ "hive", "run", task.slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      now: Time.now.utc
    )
  end

  def with_attempt(attempt, generation, &block)
    with_attempt_context(
      attempt_id: attempt.attempt_id, task_generation: generation,
      ownership_generation: attempt.ownership_generation, &block
    )
  end

  def identity_config(project_root, provider:, model:, effort: nil, models: nil)
    fields = { "agent" => provider, "model" => model }
    fields["effort"] = effort if effort
    fields.freeze
    value = {
      "project_root" => project_root,
      "execute" => fields.dup,
      Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY => {
        "execute" => fields, "open_pr" => {}, "review.fix" => {}, "review.ci" => {}
      }.freeze
    }
    value["models"] = models if models
    value
  end
end
