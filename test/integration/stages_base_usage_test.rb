require "test_helper"
require "json"
require "hive/stages/base"
require "hive/task"
require "hive/usage_db"

class StagesBaseUsageTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @old_bin = ENV["HIVE_CLAUDE_BIN"]
    @old_usage_database = Hive::UsageDb.database
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @old_bin
    Hive::UsageDb.database = @old_usage_database
    %w[
      HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
      HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
    ].each { |key| ENV.delete(key) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(root, stage = "2-brainstorm", slug = "usage-task-260524-abcd")
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    prepare_test_task_lease_repository(folder)
    Hive::Task.new(folder)
  end

  def with_usage_db(_root)
    Hive::UsageDb.database = Hive::TaskCounter.database
    yield
  end

  def configure_fake_agent(task, usage: true, exit_code: 0)
    ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = usage ? usage_result_json : JSON.generate("type" => "result", "result" => "done")
    ENV["HIVE_FAKE_CLAUDE_EXIT"] = exit_code.to_s
    ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
    ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"
  end

  def usage_result_json
    JSON.generate(
      "type" => "result",
      "result" => "done",
      "usage" => {
        "input_tokens" => 321,
        "output_tokens" => 123,
        "cache_read_input_tokens" => 20,
        "cache_creation_input_tokens" => 10
      },
      "modelUsage" => {
        "claude-opus-4-7" => { "inputTokens" => 321 }
      }
    )
  end

  def token_usage_rows
    require "sqlite3"

    db = SQLite3::Database.new(Hive::UsageDb.database.path)
    db.results_as_hash = true
    db.execute("SELECT * FROM token_usage ORDER BY started_at")
  ensure
    db&.close
  end

  def spawn(task, profile: nil, **kwargs)
    Hive::Lock.with_task_lock(task.folder, op: "test-stage-usage") do
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "collect usage",
        max_budget_usd: 1,
        timeout_sec: 5,
        profile: profile,
        **kwargs
      )
    end
  end

  def test_spawn_agent_records_one_usage_row
    with_tmp_dir do |root|
      task = make_task(root, "2-brainstorm", "usage-task-260524-abcd")
      with_usage_db(root) do
        configure_fake_agent(task)

        result = spawn(task)
        rows = token_usage_rows

        assert_equal :waiting, result[:status]
        assert_equal 1, rows.size
        row = rows.first
        assert_equal "claude", row.fetch("agent")
        assert_equal "claude-opus-4-7", row.fetch("model")
        assert_equal File.basename(root), row.fetch("project_slug")
        assert_equal "usage-task-260524-abcd", row.fetch("task_slug")
        assert_equal "2-brainstorm", row.fetch("stage")
        assert_equal 321, row.fetch("input")
        assert_equal 123, row.fetch("output")
        assert_equal 30, row.fetch("cached")
      end
    end
  end

  def test_attempt_bound_spawn_records_one_session_and_exact_usage_attribution
    with_tmp_dir do |root|
      task = make_task(root, "2-brainstorm", "usage-task-260524-abcd")
      registered_project = Hive::TaskCounter.database.read do |db|
        db[:projects].where(state_root_path: File.join(root, ".hive-state")).get(:name)
      end
      context = Hive::Attempts::Context.send(
        :new, attempt_id: "attempt-1", task_generation: 3,
        ownership_generation: "owner-3", project: registered_project,
        task_slug: task.slug, intended_stage: "2-brainstorm"
      )
      store = Hive::Attempts::Repository.new(
        root: File.join(root, "attempts"),
        database: Hive::TaskCounter.database,
        migrate: false
      )
      generation = Struct.new(
        :task_id, :project, :task_slug, :progress_token, :task_input_epoch
      ).new(task.id, registered_project, task.slug, "progress-1", 3)
      store.observe_task_source(
        task: task, generation: generation, observed_at: Time.utc(2026, 8, 12, 10)
      )
      store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1",
        task_id: task.id,
        project: registered_project, task_slug: task.slug,
        intended_stage: "2-brainstorm", task_generation: "owner-3",
        ownership_generation: "owner-3", task_input_epoch: 3,
        progress_token: "progress-1", provider: "claude",
        worker_argv: [ "hive", "run", task.slug ],
        claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
        starting_revision: "a" * 40, retry_charge: 0,
        inherited_outputs: [], launch_timeout_sec: 30,
        now: Time.utc(2026, 8, 12, 10)
      )
      with_usage_db(root) do
        configure_fake_agent(task)
        journal_activity_kinds = lambda do
          path = File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
          next [] unless File.exist?(path)

          Hive::TaskProjection.read_journal(path).filter_map do |record|
            record.dig("payload", "activity_kind")
          end
        end
        custody_observations = []
        agent_custody = lambda do |&agent_run|
          custody_observations << journal_activity_kinds.call
          result = agent_run.call
          custody_observations << journal_activity_kinds.call
          result
        end
        with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
          with_replaced_singleton_method(Hive::Attempts::Repository, :new, ->(**) { store }) do
            result = spawn(task, agent_custody: agent_custody)
            assert_equal :waiting, result[:status]
          end
        end

        events = Hive::TaskProjection.read_journal(
          File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
        ).select do |record|
          %w[session_started session_finished].include?(
            record.dig("payload", "activity_kind")
          )
        end
        assert_equal 2, events.length
        assert_equal [ [ "session_started" ], [ "session_started" ] ],
                     custody_observations,
                     "only the untrusted provider call belongs inside artifact custody"
        session_ids = events.map { |record| record.dig("payload", "session_id") }.uniq
        assert_equal 1, session_ids.length

        exact = Hive::UsageDb.exact_attempt(attempt_id: "attempt-1", task_generation: 3)
        assert exact.fetch(:available)
        assert_equal session_ids.first, exact.fetch(:sessions).first.fetch(:session_id)
        assert_equal({ input: 321, output: 123, cached: 30 }, exact.fetch(:totals))
      end
    end
  end

  def test_restore_failure_suppresses_post_spawn_task_local_session_writes
    with_tmp_dir do |root|
      task = make_task(root)
      configure_fake_agent(task, usage: false)
      observation = Object.new
      starts = 0
      finishes = 0
      observation.define_singleton_method(:session_id) { "session-unsafe" }
      observation.define_singleton_method(:start!) { starts += 1 }
      observation.define_singleton_method(:finish!) { |*| finishes += 1 }
      custody = Object.new
      custody.define_singleton_method(:call) { |&provider| provider.call }
      custody.define_singleton_method(:safe_after?) { false }

      with_replaced_singleton_method(
        Hive::Stages::Base, :session_observation, ->(**) { observation }
      ) do
        result = spawn(task, agent_custody: custody)

        assert_equal :waiting, result[:status]
      end

      assert_equal 1, starts
      assert_equal 0, finishes,
                   "a failed restoration must not write through a possibly substituted task path"
    end
  end

  def test_preflight_failure_does_not_require_agent_custody
    with_tmp_dir do |root|
      task = make_task(root)
      calls = 0
      custody = lambda do |&provider|
        calls += 1
        provider.call
      end

      with_replaced_singleton_method(
        Hive::AgentRuntime, :prepare!,
        ->(*, **) { raise Hive::AgentError, "profile unavailable" }
      ) do
        result = spawn(task, agent_custody: custody)

        assert_equal :error, result[:status]
        assert_includes result[:error_message], "profile unavailable"
      end

      assert_equal 0, calls, "no custody window exists before a provider launches"
    end
  end

  def test_spawn_without_usage_extractor_inserts_no_row
    with_tmp_dir do |root|
      task = make_task(root)
      with_usage_db(root) do
        configure_fake_agent(task, usage: false)
        profile = Hive::AgentProfile.new(
          name: :no_usage,
          bin_default: FAKE_BIN,
          env_bin_override_key: "HIVE_CLAUDE_BIN",
          headless_flag: "-p",
          version_flag: "--version",
          skill_syntax_format: "/%{skill}",
          status_detection_mode: :state_file_marker
        )

        result = spawn(task, profile: profile)

        assert_equal :waiting, result[:status]
        assert_empty token_usage_rows
      end
    end
  end

  def test_non_claude_profile_model_effort_warning_is_logged
    with_tmp_dir do |root|
      task = make_task(root)
      with_usage_db(root) do
        configure_fake_agent(task, usage: false)
        profile = Hive::AgentProfile.new(
          name: :codex,
          bin_default: FAKE_BIN,
          env_bin_override_key: "HIVE_CLAUDE_BIN",
          headless_flag: "-p",
          version_flag: "--version",
          skill_syntax_format: "/%{skill}",
          status_detection_mode: :state_file_marker
        )

        result = spawn(task, profile: profile, model: "opus", effort: "high")

        assert_equal :waiting, result[:status]
        warning = File.read(File.join(task.log_dir, "config-warnings.log"))
        assert_includes warning, "agent profile :codex does not honor per-stage model=\"opus\", effort=\"high\""
      end
    end
  end

  def test_non_claude_profile_model_effort_warning_falls_back_to_stderr
    task = Struct.new(:log_dir).new(File.join(Dir.tmpdir, "hive-warning-as-file"))
    profile = Struct.new(:name).new(:codex)
    File.write(task.log_dir, "not a directory\n")

    _out, err = capture_io do
      Hive::Stages::Base.warn_model_effort_dropped(task, profile, model: "opus", effort: nil)
    end

    assert_includes err, "agent profile :codex does not honor per-stage model=\"opus\""
  ensure
    FileUtils.rm_f(task&.log_dir)
  end

  def test_non_zero_exit_still_records_captured_usage
    with_tmp_dir do |root|
      task = make_task(root)
      with_usage_db(root) do
        configure_fake_agent(task, exit_code: 1)

        result = spawn(task)
        rows = token_usage_rows

        assert_equal :error, result[:status]
        assert_equal 1, rows.size
        assert_equal 321, rows.first.fetch("input")
      end
    end
  end

  def test_usage_db_failure_does_not_fail_spawn
    with_tmp_dir do |root|
      task = make_task(root)
      configure_fake_agent(task)
      Hive::UsageDb.database = Hive::RuntimeControlPlane::Database.new(path: root)

      _out, err = capture_io do
        result = spawn(task)
        assert_equal :waiting, result[:status]
      end

      assert_match(/usage record failed/, err)
    end
  end
  def test_base_usage_helpers_handle_synthetic_task_shapes
    project_task = Struct.new(:project_root, :folder).new("/tmp/project-alpha", "/tmp/project-alpha/.hive-state/stages/6-review/slug")
    folder_task = Struct.new(:folder).new("/tmp/project/.hive-state/stages/6-review/slug")
    stage_task = Struct.new(:stage_name, :folder).new("6-review", "/tmp/project/.hive-state/stages/6-review/slug")

    assert_equal "project-alpha", Hive::Stages::Base.usage_project_slug(project_task)
    assert_nil Hive::Stages::Base.usage_project_slug(folder_task)
    assert_equal "slug", Hive::Stages::Base.usage_task_slug(folder_task)
    assert_equal "6-review", Hive::Stages::Base.usage_stage_label(stage_task)
    assert_equal "6-review", Hive::Stages::Base.usage_stage_label(folder_task)
  end

  def test_record_usage_warns_and_continues_when_usage_db_fails
    task = Struct.new(:project_name, :slug, :stage_index, :stage_name, :folder).new(
      "alpha", "slug", 6, "review", "/tmp/slug"
    )
    profile = Struct.new(:name).new(:claude)

    _out, err = capture_io do
      with_replaced_singleton_method(Hive::UsageDb, :record!, ->(**_kwargs) { raise "db locked" }) do
        assert_nil Hive::Stages::Base.record_usage(
          task,
          profile,
          { usage: { input: 1, output: 2, cached: 3 }, model: "m" },
          Time.utc(2026, 5, 25)
        )
      end
    end

    assert_match(/usage record failed: db locked/, err)
  end

  def test_record_usage_keeps_harness_admission_and_observed_route_separate
    task = Struct.new(:project_name, :slug, :stage_index, :stage_name, :folder).new(
      "alpha", "slug", 4, "execute", "/tmp/slug"
    )
    profile = Struct.new(:name, :billing_semantics).new(:opencode, :unknown)
    context = Hive::Attempts::Context.send(
      :new,
      attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-3", project: "alpha", task_slug: "slug",
      intended_stage: "4-execute",
      routing: {
        "mode" => "explicit",
        "route" => {
          "provider_account_id" => "anthropic-subscription",
          "adapter" => "opencode", "launch_binding_id" => "default",
          "model" => "anthropic/claude-requested", "effort" => nil,
          "billing_route" => "subscription",
          "billing_evidence_source" => "provider_account_config"
        }
      }
    )
    recorded = nil
    result = {
      model: "anthropic/claude-actual",
      requested_route: "anthropic/claude-requested",
      actual_route: "anthropic/claude-actual",
      actual_provider: "anthropic",
      actual_model: "claude-actual",
      route_resolution_status: :resolved_differently,
      usage: {
        input: nil, output: 0, cached: nil,
        cache_read: nil, cache_write: 0, reasoning: nil,
        input_includes_cache_read: false,
        input_includes_cache_write: false,
        output_includes_reasoning: nil,
        provider_reported_cost: 0.0
      }
    }

    with_replaced_singleton_method(
      Hive::UsageDb, :record!, ->(**attributes) { recorded = attributes; true }
    ) do
      Hive::Stages::Base.record_usage(
        task, profile, result, Time.utc(2026, 8, 12),
        context: context, session_id: "session-1"
      )
    end

    assert_equal "opencode", recorded.fetch(:harness)
    assert_equal "subscription", recorded.fetch(:billing_route)
    assert_equal "provider_account_config", recorded.fetch(:billing_evidence_source)
    assert_equal "anthropic/claude-requested", recorded.fetch(:requested_route)
    assert_equal "anthropic/claude-actual", recorded.fetch(:actual_route)
    assert_equal "anthropic", recorded.fetch(:actual_provider)
    assert_equal "claude-actual", recorded.fetch(:actual_model)
    assert_equal false, recorded.fetch(:input_includes_cache_read)
    assert_equal 0.0, recorded.fetch(:provider_reported_cost)
  end
end
