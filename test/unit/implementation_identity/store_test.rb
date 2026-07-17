require "test_helper"
require "hive/attempts/context"
require "hive/implementation_identity/store"

class ImplementationIdentityStoreTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:folder, :state_file, :slug, :id, :project_root, keyword_init: true)

  def test_capture_is_durable_before_callback_and_reused_across_config_drift
    with_identity_attempt do |task, attempt_store, attempt|
      cfg = execute_config("codex", "gpt-5.6-sol")
      store = Hive::ImplementationIdentity::Store.new(
        task: task, cfg: cfg, attempt_store: attempt_store
      )
      observed = nil

      with_attempt_context(
        attempt_id: attempt.attempt_id, task_generation: 1,
        ownership_generation: attempt.ownership_generation
      ) do
        first = store.capture_execute!
        observed = File.readlines(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)).map do |line|
          JSON.parse(line)
        end
        drifted = Hive::ImplementationIdentity::Store.new(
          task: task, cfg: execute_config("claude", "claude-fable-5"),
          attempt_store: attempt_store
        ).capture_execute!

        assert_equal "codex", first.provider
        assert_equal first.to_h, drifted.to_h
      end

      assert_equal %w[generation_advanced implementation_identity_captured],
                   observed.map { |record| record["event_type"] }
      projection = Hive::TaskProjection::Store.new(
        task_folder: task.folder, attempt_store: attempt_store
      ).read
      assert_equal "codex", projection["implementation_identity"].dig("execute", "provider")
    end
  end

  def test_append_failure_aborts_before_spawn_boundary
    with_identity_attempt do |task, attempt_store, attempt|
      writer = Object.new
      writer.define_singleton_method(:path) do
        File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
      end
      writer.define_singleton_method(:append_idempotent) do |*_args, **_kwargs|
        raise Hive::TaskJournal::Error, "disk full"
      end
      store = Hive::ImplementationIdentity::Store.new(
        task: task, cfg: execute_config("codex", "gpt-5.6-sol"),
        attempt_store: attempt_store, writer: writer
      )
      spawned = false

      assert_raises(Hive::TaskJournal::Error) do
        with_attempt_context(
          attempt_id: attempt.attempt_id, task_generation: 1,
          ownership_generation: attempt.ownership_generation
        ) do
          store.capture_execute!
          spawned = true
        end
      end
      refute spawned
    end
  end

  def test_downstream_resolution_is_journaled_before_launch_and_matches_native_arguments
    with_identity_attempt(intended_stage: "5-open-pr", attempt_id: "open-pr-attempt") do |task, attempt_store, attempt|
      execute_cfg = execute_config("codex", "gpt-5.6-sol")
      seed_execute_identity(task, attempt_store, execute_cfg)
      store = Hive::ImplementationIdentity::Store.new(
        task: task, cfg: execute_cfg, attempt_store: attempt_store
      )

      selection = Hive::Attempts::Context.with(
        attempt_id: attempt.attempt_id, task_generation: 1,
        ownership_generation: attempt.ownership_generation
      ) { store.resolve_stage!("open_pr") }

      assert_equal [ "--model", "gpt-5.6-terra", "-c", "model_reasoning_effort=medium" ],
                   selection.native_arguments
      events = File.readlines(File.join(task.folder, "events.jsonl")).map { |line| JSON.parse(line) }
      stage_event = events.find { |record| record["event_type"] == "implementation_stage_resolved" }
      assert_equal "open_pr", stage_event.dig("payload", "identity", "stage")
      assert_equal selection.to_h.except("native_arguments"), stage_event.dig("payload", "identity")
    end
  end

  private

  def with_identity_attempt(intended_stage: "4-execute", attempt_id: "execute-attempt")
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = TaskStub.new(
        folder: folder, state_file: File.join(folder, "task.md"), slug: "identity-task",
        id: 42, project_root: root
      )
      File.write(task.state_file, "body")
      File.write(File.join(folder, "plan.md"), "# plan\n")
      attempt_store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      attempt = attempt_store.create_launching(
        attempt_id: attempt_id, request_id: "request", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: task.slug, intended_stage: intended_stage,
        task_generation: "owner-1", ownership_generation: "owner-1", task_input_epoch: 1,
        progress_token: "progress", provider: "codex", starting_revision: nil,
        worker_argv: [ "hive", "run", task.slug ],
        claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
      )
      yield task, attempt_store, attempt
    end
  end

  def seed_execute_identity(task, attempt_store, cfg)
    execute_attempt = attempt_store.create_launching(
      attempt_id: "seed-execute", request_id: "seed", predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: task.slug, intended_stage: "4-execute",
      task_generation: "owner-1", ownership_generation: "owner-1", task_input_epoch: 1,
      progress_token: "seed-progress", provider: "codex", starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
    )
    Hive::Attempts::Context.with(
      attempt_id: execute_attempt.attempt_id, task_generation: 1,
      ownership_generation: execute_attempt.ownership_generation
    ) do
      Hive::ImplementationIdentity::Store.new(
        task: task, cfg: cfg, attempt_store: attempt_store
      ).capture_execute!
    end
  end

  def execute_config(provider, model)
    fields = { "agent" => provider, "model" => model }.freeze
    {
      "project_root" => "/tmp/project",
      "execute" => fields.dup,
      Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY => {
        "execute" => fields, "open_pr" => {}, "review.fix" => {}, "review.ci" => {}
      }.freeze
    }
  end
end
