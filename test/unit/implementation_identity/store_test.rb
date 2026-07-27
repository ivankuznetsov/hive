require "test_helper"
require "hive/attempts/context"
require "hive/implementation_identity/store"

class ImplementationIdentityStoreTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :folder, :state_file, :slug, :id, :project_root, :workflow,
    keyword_init: true
  )

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

      selection = with_attempt_context(
        attempt_id: attempt.attempt_id, task_generation: 1,
        ownership_generation: attempt.ownership_generation
      ) { store.resolve_stage!("open_pr") }

      assert_equal [ "--model", "gpt-5.6-terra", "-c", "model_reasoning_effort=medium" ],
                   selection.native_arguments
      events = File.readlines(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)).map do |line|
        JSON.parse(line)
      end
      stage_event = events.find { |record| record["event_type"] == "implementation_stage_resolved" }
      assert_equal "open_pr", stage_event.dig("payload", "identity", "stage")
      assert_equal selection.to_h.except("native_arguments"), stage_event.dig("payload", "identity")
    end
  end

  def test_downstream_resolution_reuses_first_generation_stage_across_attempt_and_config_drift
    with_identity_attempt(
      intended_stage: "5-open-pr", attempt_id: "open-pr-first"
    ) do |task, attempt_store, first_attempt|
      seed_execute_identity(task, attempt_store, execute_config("codex", "gpt-5.6-sol"))
      first_cfg = execute_config(
        "codex", "gpt-5.6-sol",
        models: { "open_pr" => { "model" => "gpt-5.6-first" } }
      )
      first = with_attempt_context(
        attempt_id: first_attempt.attempt_id, task_generation: 1,
        ownership_generation: first_attempt.ownership_generation
      ) do
        Hive::ImplementationIdentity::Store.new(
          task: task, cfg: first_cfg, attempt_store: attempt_store
        ).resolve_stage!("open_pr")
      end
      retry_attempt = create_attempt(
        attempt_store, task, attempt_id: "open-pr-retry", intended_stage: "5-open-pr"
      )
      drifted_cfg = execute_config(
        "claude", "claude-fable-5",
        models: { "open_pr" => { "model" => "claude-opus-4-6" } }
      )
      drifted = with_attempt_context(
        attempt_id: retry_attempt.attempt_id, task_generation: 1,
        ownership_generation: retry_attempt.ownership_generation
      ) do
        Hive::ImplementationIdentity::Store.new(
          task: task, cfg: drifted_cfg, attempt_store: attempt_store
        ).resolve_stage!("open_pr")
      end

      assert_equal first.to_h, drifted.to_h
      assert_equal "open-pr-first", drifted.originating_attempt
      assert_equal(
        1,
        journal(task).count { |event| event["event_type"] == "implementation_stage_resolved" }
      )
      event = journal(task).find { |record| record["event_type"] == "implementation_stage_resolved" }
      refute event.dig("payload", "idempotency_key").end_with?("/open-pr-first")
      assert_equal "open_pr", event.dig("payload", "identity", "routing", "stage")
      refute event.dig("payload", "identity").key?("native_arguments")
    end
  end

  def test_invalid_routed_execute_selection_appends_nothing
    with_identity_attempt do |task, attempt_store, attempt|
      cfg = execute_config(
        "pi", "provider/model-v1",
        models: { "execute_implementation" => { "effort" => "high" } }
      )

      assert_raises(Hive::ConfigError) do
        with_attempt_context(
          attempt_id: attempt.attempt_id, task_generation: 1,
          ownership_generation: attempt.ownership_generation
        ) do
          Hive::ImplementationIdentity::Store.new(
            task: task, cfg: cfg, attempt_store: attempt_store
          ).capture_execute!
        end
      end

      assert_empty journal(task)
    end
  end

  def test_invalid_routed_downstream_selection_does_not_change_journal
    with_identity_attempt(
      intended_stage: "6-review", attempt_id: "review-fix-invalid"
    ) do |task, attempt_store, attempt|
      base = execute_config("pi", "provider/model-v1")
      seed_execute_identity(task, attempt_store, base)
      before = File.binread(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
      cfg = execute_config(
        "pi", "provider/model-v1",
        models: { "review_fix" => { "effort" => "high" } }
      )

      assert_raises(Hive::ConfigError) do
        with_attempt_context(
          attempt_id: attempt.attempt_id, task_generation: 1,
          ownership_generation: attempt.ownership_generation
        ) do
          Hive::ImplementationIdentity::Store.new(
            task: task, cfg: cfg, attempt_store: attempt_store
          ).resolve_stage!("review.fix")
        end
      end

      assert_equal before, File.binread(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
    end
  end

  def test_conflicting_stage_append_returns_the_first_projected_winner
    with_identity_attempt(
      intended_stage: "5-open-pr", attempt_id: "open-pr-racer"
    ) do |task, attempt_store, attempt|
      cfg = execute_config("codex", "gpt-5.6-sol")
      resolver = Hive::ImplementationIdentity::Resolver.new(cfg: cfg)
      execute = resolver.resolve_execute(generation: 1, attempt_id: "execute-first")
      winner = resolver.resolve_stage(
        "open_pr", execute_identity: execute, attempt_id: "open-pr-winner"
      )
      rebuilt = false
      projection_store = Object.new
      projection_store.define_singleton_method(:read) do
        {
          "implementation_identity" => {
            "execute" => execute.to_h.except("native_arguments"),
            "stages" => (
              rebuilt ? { "open_pr" => winner.to_h.except("native_arguments") } : {}
            )
          }
        }
      end
      projection_store.define_singleton_method(:rebuild!) { rebuilt = true }
      captured_key = nil
      writer = Object.new
      writer.define_singleton_method(:path) do
        File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
      end
      writer.define_singleton_method(:append_idempotent) do |*, idempotency_key:|
        captured_key = idempotency_key
        raise Hive::TaskJournal::Conflict, "first writer won"
      end
      store = Hive::ImplementationIdentity::Store.new(
        task: task, cfg: cfg, attempt_store: attempt_store,
        writer: writer, projection_store: projection_store, resolver: resolver
      )

      selection = with_attempt_context(
        attempt_id: attempt.attempt_id, task_generation: 1,
        ownership_generation: attempt.ownership_generation
      ) { store.resolve_stage!("open_pr") }

      assert_equal "open-pr-winner", selection.originating_attempt
      assert_equal "id:42/1/open_pr", captured_key
    end
  end

  def test_conflicting_stage_append_without_a_projected_winner_remains_an_error
    with_identity_attempt(
      intended_stage: "5-open-pr", attempt_id: "open-pr-racer"
    ) do |task, attempt_store, attempt|
      cfg = execute_config("codex", "gpt-5.6-sol")
      execute = Hive::ImplementationIdentity::Resolver.new(cfg: cfg).resolve_execute(
        generation: 1, attempt_id: "execute-first"
      )
      projection_store = Object.new
      projection_store.define_singleton_method(:read) do
        {
          "implementation_identity" => {
            "execute" => execute.to_h.except("native_arguments"),
            "stages" => {}
          }
        }
      end
      projection_store.define_singleton_method(:rebuild!) { }
      writer = Object.new
      writer.define_singleton_method(:path) do
        File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
      end
      writer.define_singleton_method(:append_idempotent) do |*, **|
        raise Hive::TaskJournal::Conflict, "unprojected conflict"
      end
      store = Hive::ImplementationIdentity::Store.new(
        task: task, cfg: cfg, attempt_store: attempt_store,
        writer: writer, projection_store: projection_store
      )

      assert_raises(Hive::TaskJournal::Conflict) do
        with_attempt_context(
          attempt_id: attempt.attempt_id, task_generation: 1,
          ownership_generation: attempt.ownership_generation
        ) { store.resolve_stage!("open_pr") }
      end
    end
  end

  def test_store_rejects_unknown_downstream_stage_before_context_or_projection
    task = TaskStub.new(folder: "/tmp/task", slug: "task", id: 42)
    store = Hive::ImplementationIdentity::Store.new(
      task: task, cfg: execute_config("codex", "gpt-5.6-sol")
    )

    assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      store.resolve_stage!("artifacts")
    end
  end

  def test_ensure_execute_reconstructs_legacy_identity_and_reports_current_generation
    with_identity_attempt(intended_stage: "5-open-pr", attempt_id: "legacy-open-pr") do |task, attempt_store, attempt|
      store = Hive::ImplementationIdentity::Store.new(
        task: task, cfg: execute_config("codex", "gpt-5.6-sol"),
        attempt_store: attempt_store
      )

      selection = with_attempt_context(
        attempt_id: attempt.attempt_id, task_generation: 1,
        ownership_generation: attempt.ownership_generation
      ) { store.ensure_execute! }

      assert_equal "codex", selection.provider
      assert_equal "legacy_backfill", selection.source
    end
  end

  def test_capture_rejects_attempt_generation_mismatch
    with_identity_attempt do |task, attempt_store, attempt|
      decision = Hive::Conditions::GenerationDecision.new(
        task_generation: 2, input_fingerprint: "fingerprint", advanced: false,
        reason: "accepted_input_changed", invalidation_token: nil
      )
      tracker = Object.new
      tracker.define_singleton_method(:resolve) { |**_kwargs| decision }
      store = Hive::ImplementationIdentity::Store.new(
        task: task, cfg: execute_config("codex", "gpt-5.6-sol"),
        attempt_store: attempt_store, generation_tracker: tracker
      )

      error = assert_raises(Hive::Conditions::GenerationMismatch) do
        with_attempt_context(
          attempt_id: attempt.attempt_id, task_generation: 1,
          ownership_generation: attempt.ownership_generation
        ) { store.capture_execute! }
      end

      assert_match(/owns generation 1, but current inputs require 2/, error.message)
    end
  end

  def test_default_attempt_store_honors_explicit_root
    with_tmp_dir do |root|
      task = TaskStub.new(
        folder: root, state_file: File.join(root, "task.md"), slug: "task",
        id: 1, project_root: root
      )

      with_env("HIVE_ATTEMPT_STORE_ROOT" => File.join(root, "attempts")) do
        store = Hive::ImplementationIdentity::Store.new(
          task: task, cfg: execute_config("codex", "gpt-5.6-sol")
        )

        assert_equal File.join(root, "attempts"),
                     store.instance_variable_get(:@attempt_store).root
      end
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
      worker_argv: [ "hive", "run", task.slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
    )
    with_attempt_context(
      attempt_id: execute_attempt.attempt_id, task_generation: 1,
      ownership_generation: execute_attempt.ownership_generation
    ) do
      Hive::ImplementationIdentity::Store.new(
        task: task, cfg: cfg, attempt_store: attempt_store
      ).capture_execute!
    end
  end

  def create_attempt(attempt_store, task, attempt_id:, intended_stage:, generation: 1)
    attempt_store.create_launching(
      attempt_id: attempt_id, request_id: "request-#{attempt_id}",
      predecessor_attempt_id: nil, task_id: task.id.to_s, project: "demo",
      task_slug: task.slug, intended_stage: intended_stage,
      task_generation: "owner-#{generation}", ownership_generation: "owner-#{generation}",
      task_input_epoch: generation, progress_token: "progress-#{attempt_id}",
      provider: "codex", starting_revision: nil,
      worker_argv: [ "hive", "run", task.slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30,
      now: Time.now.utc
    )
  end

  def execute_config(provider, model, models: nil)
    fields = { "agent" => provider, "model" => model }.freeze
    value = {
      "project_root" => "/tmp/project",
      "execute" => fields.dup,
      Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY => {
        "execute" => fields, "open_pr" => {}, "review.fix" => {}, "review.ci" => {}
      }.freeze
    }
    value["models"] = models if models
    value
  end

  def journal(task)
    Hive::TaskProjection.read_journal(
      File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
    )
  end
end
