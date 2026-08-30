require "test_helper"
require "json"
require "tmpdir"
require "hive/daemon/status_consumer"

# Pin StatusConsumer's mapping of Hive's in-process task graph into daemon
# rows. Tests inject hashes at the object boundary; the real-producer test
# separately proves the default path stays in-process.
class HiveDaemonStatusConsumerTest < Minitest::Test
  include HiveTestHelper

  def test_injected_producer_passes_the_graph_without_serialization
    payload = make_envelope(projects: [])
    producer = lambda do |task_keys:, warnings:|
      assert_nil task_keys
      assert_empty warnings
      payload
    end

    with_replaced_singleton_method(
      Open3, :capture3, ->(*) { flunk "daemon status must not spawn the Hive CLI" }
    ) do
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch

      assert result.ok, result.error
      assert_same payload, result.status_payload
    end
  end

  def test_default_producer_builds_the_graph_without_a_status_subprocess
    require "hive/commands/status"

    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
      with_replaced_singleton_method(
        Open3, :capture3, ->(*) { flunk "daemon status must not spawn the Hive CLI" }
      ) do
        result = Hive::Daemon::StatusConsumer.new.fetch

        assert result.ok, result.error
        assert_equal [], result.rows
        assert_equal [], result.status_payload.fetch("projects")
      end
    end
  end

  def test_default_bounded_producer_maps_a_real_task_and_captures_nested_warnings
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "changed-task-260830-abcd"
      folder = File.join(hive_state, "stages", "1-inbox", slug)
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "idea.md")
      File.write(state_file, "<!-- WAITING -->\n")
      File.write(File.join(folder, "meta.yml"), "id: [not-valid\n")
      Hive::TaskProjection::Store.new(task_folder: folder).rebuild!(
        marker: Hive::Markers.current(state_file)
      )

      completed_slug = "completed-task-260830-abcd"
      completed_folder = File.join(hive_state, "stages", "9-done", completed_slug)
      FileUtils.mkdir_p(completed_folder)
      completed_state_file = File.join(completed_folder, "task.md")
      File.write(completed_state_file, "<!-- COMPLETE -->\n")
      Hive::TaskMeta.write(
        completed_folder, id: nil, slug: completed_slug, display_name: nil,
        completed_at: Time.now.utc
      )
      Hive::TaskProjection::Store.new(task_folder: completed_folder).rebuild!(
        marker: Hive::Markers.current(completed_state_file)
      )

      workflows_dir = File.join(hive_state, "workflows")
      FileUtils.mkdir_p(workflows_dir)
      File.write(File.join(workflows_dir, "broken.yml"), "id: [not-valid\n")
      File.write(File.join(workflows_dir, "warning-flow.yml"), <<~YAML)
        id: warning-flow
        stages:
          - name: review
            kind: council
            state_file: review.md
            reviewers:
              - name: one
                prompt: Review.
            council:
              revise:
                skill: /revise
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      managed_lock = File.join(
        workflows_dir, "managed", Hive::WorkflowPackage::ManagedStore::LOCK_FILE
      )
      FileUtils.mkdir_p(File.dirname(managed_lock))
      File.write(managed_lock, "{not-json")
      File.write(File.join(hive_state, "config.yml"), <<~YAML)
        bot:
          notification_dedupe_window_sec: 600
      YAML
      Hive::Workflows::Project.reset!
      project = {
        "name" => "demo", "path" => project_root, "hive_state_path" => hive_state
      }
      task_meta_read = Hive::TaskMeta.method(:read)
      invalid_completion_time = lambda do |task_folder|
        meta = task_meta_read.call(task_folder)
        task_folder == completed_folder ? meta.merge(completed_at: "not-a-timestamp") : meta
      end

      result = nil
      _stdout, stderr = capture_io do
        with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
          with_replaced_singleton_method(Hive::TaskMeta, :read, invalid_completion_time) do
            with_replaced_singleton_method(
              Open3, :capture3, ->(*) { flunk "bounded daemon status must not spawn the Hive CLI" }
            ) do
              result = Hive::Daemon::StatusConsumer.new.fetch_tasks(
                [ [ "demo", slug ], [ "demo", completed_slug ] ]
              )
            end
          end
        end
      end

      assert result.ok, result.error
      assert_equal [ slug, completed_slug ].sort, result.rows.map(&:slug).sort
      assert_nil result.status_payload
      assert_includes result.warning, "hive: skipping"
      assert_includes result.warning, "broken.yml"
      assert_includes result.warning, "hive: task_meta: failed to read"
      assert_includes result.warning, "council declares a revise agent with max_rounds: 1"
      assert_includes result.warning, "bot.notification_dedupe_window_sec"
      assert_includes result.warning, 'skipping managed workflow "managed"'
      assert_includes result.warning, "hive: completion_time: invalid completed_at"
      assert_empty stderr
    ensure
      Hive::Workflows::Project.reset!
    end
  end

  def with_status(payload, expected_task_keys: nil, warning_text: "")
    warning_messages = warning_text.to_s.lines(chomp: true).reject(&:empty?)
    producer = lambda do |task_keys:, warnings:|
      expected_task_keys.nil? ? assert_nil(task_keys) : assert_equal(expected_task_keys, task_keys)
      warnings.concat(warning_messages)
      payload
    end
    yield(producer)
  end

  def make_envelope(projects: [])
    {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS["hive-status"],
      "ok" => true,
      "generated_at" => Time.now.utc.iso8601,
      "projects" => projects
    }
  end

  def task_row(slug:, stage: "1-inbox", marker: "waiting",
               action: "ready_to_brainstorm", command: "hive brainstorm slug",
               mtime: Time.now.utc.iso8601)
    {
      "stage" => stage,
      "slug" => slug,
      "folder" => "/tmp/p/#{stage}/#{slug}",
      "state_file" => "/tmp/p/#{stage}/#{slug}/idea.md",
      "marker" => marker,
      "attrs" => {},
      "mtime" => mtime,
      "age_seconds" => 0,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => action,
      "action_label" => "Ready to brainstorm",
      "suggested_command" => command,
      "depends_on" => nil,
      "blocked_by" => nil,
      "dependency_stage" => nil,
      "blocked" => false,
      "admission_error" => nil
    }
  end

  # ── happy path ────────────────────────────────────────────────────────

  def test_parses_envelope_into_rows
    plan_review = {
      "review_id" => "pr-#{'a' * 64}", "state" => "cleared",
      "effective_level" => "standard", "execution_allowed" => true
    }
    payload = make_envelope(projects: [ {
      "name" => "writero",
      "path" => "/tmp/writero",
      "hive_state_path" => "/tmp/writero/.hive-state",
      "hidden_archived_task_count" => 3,
      "tasks" => [
        task_row(slug: "fix-bug").merge(
          "pr_url" => "https://github.com/acme/writero/pull/42",
          "plan_review" => plan_review,
          "projection_repair" => true
        )
      ]
    } ])
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      assert result.ok, "expected ok=true; got error #{result.error.inspect}"
      assert_equal 1, result.rows.size
      row = result.rows.first
      assert_equal "writero", row.project
      assert_equal "fix-bug", row.slug
      assert_equal "ready_to_brainstorm", row.action
      assert_equal "hive brainstorm slug", row.suggested_command
      assert_equal "https://github.com/acme/writero/pull/42", row.pr_url
      assert_equal plan_review, row.plan_review
      assert_equal true, row.projection_repair
      assert_equal payload, result.status_payload
      assert_equal 3, result.hidden_archived_task_count
      assert_equal 3, result.projects.first.hidden_archived_task_count
    end
  end

  def test_projection_repair_requires_a_literal_json_boolean
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [
        task_row(slug: "true").merge("projection_repair" => true),
        task_row(slug: "false").merge("projection_repair" => false),
        task_row(slug: "string").merge("projection_repair" => "true")
      ]
    } ])

    with_status(payload) do |producer|
      rows = Hive::Daemon::StatusConsumer.new(producer: producer).fetch.rows
      assert_equal [ true, false, false ], rows.map(&:projection_repair)
    end
  end

  def test_fetch_tasks_requests_and_accepts_only_a_partial_envelope
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_row(slug: "changed") ]
    } ]).merge("partial" => true)
    expected = [ [ "p", "changed" ], [ "p", "other" ] ]

    with_status(payload, expected_task_keys: expected) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch_tasks(
        [ [ "p", "changed" ], [ "p", "other" ] ]
      )

      assert result.ok
      assert_equal [ "changed" ], result.rows.map(&:slug)
      assert_nil result.status_payload,
                 "bounded task reads must not replace the daemon's authoritative full graph"
    end

    without_partial = payload.reject { |key, _value| key == "partial" }
    with_status(without_partial, expected_task_keys: expected) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch_tasks(
        [ [ "p", "changed" ], [ "p", "other" ] ]
      )

      refute result.ok
      assert_includes result.error, "partial=true"
    end
  end

  def test_fetch_tasks_skips_the_producer_for_an_empty_change_set
    producer = ->(**) { flunk "empty bounded fetch must not build a graph" }
    consumer = Hive::Daemon::StatusConsumer.new(producer: producer)

    result = consumer.fetch_tasks([])

    assert result.ok
    assert_empty result.rows
  end

  def test_fetch_tasks_rejects_project_errors_and_unrequested_rows
    expected = [ [ "p", "changed" ] ]
    failed = make_envelope(projects: [ {
      "name" => "p", "error" => "project_load_failed", "tasks" => []
    } ]).merge("partial" => true)
    with_status(failed, expected_task_keys: expected) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch_tasks(
        [ [ "p", "changed" ] ]
      )

      refute result.ok
      assert_includes result.error, "project_load_failed"
    end

    wrong_project = make_envelope(projects: [ {
      "name" => "other", "tasks" => []
    } ]).merge("partial" => true)
    with_status(wrong_project, expected_task_keys: expected) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch_tasks(
        [ [ "p", "changed" ] ]
      )

      refute result.ok
      assert_includes result.error, "projects do not match"
    end

    extra = make_envelope(projects: [ {
      "name" => "p", "tasks" => [ task_row(slug: "other") ]
    } ]).merge("partial" => true)
    with_status(extra, expected_task_keys: expected) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch_tasks(
        [ [ "p", "changed" ] ]
      )

      refute result.ok
      assert_includes result.error, "unrequested task p:other"
    end
  end

  def test_missing_hidden_archived_count_defaults_to_zero_but_invalid_values_fail
    legacy = make_envelope(projects: [ {
      "name" => "legacy", "path" => "/tmp/legacy", "hive_state_path" => "/tmp/legacy/.h",
      "tasks" => []
    } ])
    with_status(legacy) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch
      assert result.ok
      assert_equal 0, result.hidden_archived_task_count
      assert_equal 0, result.projects.first.hidden_archived_task_count
    end

    malformed = make_envelope(projects: [ {
      "name" => "bad", "path" => "/tmp/bad", "hive_state_path" => "/tmp/bad/.h",
      "hidden_archived_task_count" => -1, "tasks" => []
    } ])
    with_status(malformed) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch
      refute result.ok
      assert_match(/hidden_archived_task_count/, result.error)
    end
  end

  # Issue #144: the daemon healer and dispatcher use `row.live_task_lock`
  # to recognise a live `hive run` during the pre-claude_pid window. Pin
  # the parse of the JSON key here so a regression in `task_payload`
  # (Hive::Commands::Status) or the Row struct surfaces as a structured
  # test failure rather than a silent classification change downstream.
  def test_parses_live_task_lock_field_and_coerces_to_strict_boolean
    task_true = task_row(slug: "live-runner").merge(
      "live_task_lock" => true,
      "task_lock_pid" => 12_345,
      "task_lock_process_start_time" => "observed-start",
      "task_lock_id" => "observed-generation"
    )
    task_false = task_row(slug: "no-runner").merge("live_task_lock" => false)
    task_missing = task_row(slug: "legacy-payload")
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_true, task_false, task_missing ]
    } ])
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      assert result.ok
      rows = result.rows.each_with_object({}) { |r, h| h[r.slug] = r }
      assert_equal true, rows.fetch("live-runner").live_task_lock,
                   "explicit true must propagate"
      assert_equal 12_345, rows.fetch("live-runner").task_lock_pid
      assert_equal "observed-start", rows.fetch("live-runner").task_lock_process_start_time
      assert_equal "observed-generation", rows.fetch("live-runner").task_lock_id
      assert_equal false, rows.fetch("no-runner").live_task_lock,
                   "explicit false must propagate"
      assert_equal false, rows.fetch("legacy-payload").live_task_lock,
                   "missing key must coerce to false, not nil — downstream callers compare with ==true"
    end
  end

  def test_passes_through_canonical_condition_projection_fields
    condition = { "condition" => "ChangesPresent", "state" => "satisfied" }
    task = task_row(slug: "conditioned").merge(
      "condition_task_generation" => 3,
      "commit_generation" => 2,
      "current_attempt" => "attempt-b",
      "conditions" => [ condition ],
      "condition_history" => [ condition.merge("state" => "superseded") ],
      "evidence" => [ { "type" => "commit", "sha" => "b" * 40 } ],
      "condition_overrides" => [ {
        "reason" => "forced_condition_transition", "source_command" => "approve"
      } ],
      "condition_gate" => { "status" => "eligible" },
      "condition_migration" => { "effective" => "conditions" },
      "condition_provenance" => { "projector" => "TaskProjection/v1" },
      "shadow_audit" => { "ready" => false },
      "condition_warning" => nil
    )
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task ]
    } ])

    with_status(payload) do |producer|
      row = Hive::Daemon::StatusConsumer.new(producer: producer).fetch.rows.fetch(0)
      assert_equal 3, row.condition_task_generation
      assert_equal 2, row.commit_generation
      assert_equal "attempt-b", row.current_attempt
      assert_equal [ condition ], row.conditions
      assert_equal "approve", row.condition_overrides.fetch(0).fetch("source_command")
      assert_equal "eligible", row.condition_gate.fetch("status")
      assert_equal "conditions", row.condition_migration.fetch("effective")
    end
  end

  def test_parses_dependency_fields_and_coerces_blocked_to_boolean
    task_blocked = task_row(slug: "dependent").merge(
      "depends_on" => "base",
      "blocked_by" => "base",
      "dependency_stage" => "7-artifacts",
      "blocked" => true
    )
    task_missing = task_row(slug: "legacy-payload")
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_blocked, task_missing ]
    } ])

    with_status(payload) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch

      assert result.ok
      rows = result.rows.each_with_object({}) { |row, hash| hash[row.slug] = row }
      dependent = rows.fetch("dependent")
      assert_equal "base", dependent.depends_on
      assert_equal "base", dependent.blocked_by
      assert_equal "7-artifacts", dependent.dependency_stage
      assert_equal true, dependent.blocked
      assert_equal false, rows.fetch("legacy-payload").blocked
    end
  end

  def test_parses_admission_error_and_forces_inert_row_shape
    admission = {
      "reason_code" => "dependency_cycle",
      "offending_ref" => "p:a -> p:b -> p:a",
      "safe_correction" => "Break the cycle."
    }
    task = task_row(slug: "held", action: "ready_to_archive", command: "hive archive held").merge(
      "blocked" => false,
      "admission_error" => admission
    )
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task ]
    } ])

    with_status(payload) do |producer|
      row = Hive::Daemon::StatusConsumer.new(producer: producer).fetch.rows.first

      assert_equal true, row.blocked
      assert_equal "admission_error", row.action
      assert_nil row.suggested_command
      assert_equal "dependency_cycle", row.admission_error.reason_code
      assert_equal "Break the cycle.", row.admission_error.safe_correction
    end
  end

  def test_missing_admission_field_fails_closed_even_on_known_action
    task = task_row(slug: "schema-drift")
    task.delete("admission_error")
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task ]
    } ])

    with_status(payload) do |producer|
      row = Hive::Daemon::StatusConsumer.new(producer: producer).fetch.rows.first

      assert_equal true, row.blocked
      assert_equal "admission_error", row.action
      assert_equal "dependency_validation_failed", row.admission_error.reason_code
    end
  end

  def test_malformed_admission_objects_fail_closed_per_row
    malformed = [
      "not-an-object",
      { "reason_code" => "dependency_cycle", "offending_ref" => "p:a" },
      { "reason_code" => "unknown", "offending_ref" => "p:a", "safe_correction" => "Fix it." },
      { "reason_code" => "dependency_cycle", "offending_ref" => "", "safe_correction" => "Fix it." },
      {
        "reason_code" => "dependency_cycle", "offending_ref" => "p:a",
        "safe_correction" => "Fix it.", "extra" => true
      }
    ]
    tasks = malformed.each_with_index.map do |value, index|
      task_row(slug: "malformed-#{index}").merge("admission_error" => value)
    end
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => tasks
    } ])

    with_status(payload) do |producer|
      rows = Hive::Daemon::StatusConsumer.new(producer: producer).fetch.rows

      assert_equal malformed.size, rows.size
      rows.each do |row|
        assert_equal true, row.blocked
        assert_equal "admission_error", row.action
        assert_nil row.suggested_command
        assert_equal "dependency_validation_failed", row.admission_error.reason_code
      end
    end
  end

  def test_parses_multiple_projects_and_tasks
    payload = make_envelope(projects: [
      {
        "name" => "p1", "path" => "/tmp/p1", "hive_state_path" => "/tmp/p1/.h",
        "tasks" => [
          task_row(slug: "s1", action: "ready_to_brainstorm"),
          task_row(slug: "s2", action: "needs_input", marker: "waiting")
        ]
      },
      {
        "name" => "p2", "path" => "/tmp/p2", "hive_state_path" => "/tmp/p2/.h",
        "tasks" => [ task_row(slug: "s3", action: "ready_to_archive",
                              command: "hive archive s3 --from 8-finalize") ]
      }
    ])
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      assert result.ok
      assert_equal 3, result.rows.size
      slugs = result.rows.map(&:slug).sort
      assert_equal %w[s1 s2 s3], slugs
    end
  end

  def test_empty_projects_returns_empty_rows
    payload = make_envelope(projects: [])
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      assert result.ok
      assert_equal [], result.rows
    end
  end

  def test_skips_projects_with_error_field
    # `hive status --json` emits `error: "missing_project_path"` for
    # projects whose registered path is gone. Daemon must skip those —
    # the project is unrunnable until the operator re-registers.
    payload = make_envelope(projects: [
      { "name" => "missing", "path" => "/nope", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "ok", "path" => "/tmp/ok", "hive_state_path" => "/tmp/ok/.h",
        "tasks" => [ task_row(slug: "s1") ] }
    ])
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      assert result.ok
      assert_equal 1, result.rows.size
      assert_equal "ok", result.rows.first.project
    end
  end

  def test_invalid_row_mtime_falls_back_to_state_file_mtime
    with_tmp_dir do |dir|
      state_file = File.join(dir, "idea.md")
      File.write(state_file, "<!-- WAITING -->\n")
      expected = File.mtime(state_file)

      task = task_row(slug: "mtime-fallback", mtime: "not-a-time")
      task["state_file"] = state_file
      payload = make_envelope(projects: [ {
        "name" => "writero",
        "path" => dir,
        "hive_state_path" => File.join(dir, ".hive-state"),
        "tasks" => [ task ]
      } ])

      with_status(payload) do |producer|
        consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
        result = consumer.fetch

        assert result.ok, "expected ok=true; got error #{result.error.inspect}"
        assert_in_delta expected.to_f, result.rows.first.state_file_mtime.to_f, 0.001
      end
    end
  end

  def test_invalid_row_mtime_without_state_file_returns_nil
    task = task_row(slug: "missing-mtime", mtime: "not-a-time")
    task["state_file"] = "/tmp/hive-status-consumer-missing-state-file.md"
    payload = make_envelope(projects: [ {
      "name" => "writero",
      "path" => "/tmp/writero",
      "hive_state_path" => "/tmp/writero/.hive-state",
      "tasks" => [ task ]
    } ])

    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch

      assert result.ok, "expected ok=true; got error #{result.error.inspect}"
      assert_nil result.rows.first.state_file_mtime
    end
  end

  def test_valid_row_mtime_prefers_state_file_precision
    with_tmp_dir do |dir|
      state_file = File.join(dir, "idea.md")
      File.write(state_file, "<!-- WAITING -->\n")
      expected = Time.at(1_800_000_000, 456_789, :microsecond).utc
      File.utime(expected, expected, state_file)

      task = task_row(slug: "precise-mtime", mtime: expected.utc.iso8601)
      task["state_file"] = state_file
      payload = make_envelope(projects: [ {
        "name" => "writero",
        "path" => dir,
        "hive_state_path" => File.join(dir, ".hive-state"),
        "tasks" => [ task ]
      } ])

      with_status(payload) do |producer|
        consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
        result = consumer.fetch

        assert result.ok, "expected ok=true; got error #{result.error.inspect}"
        assert_in_delta expected.to_f, result.rows.first.state_file_mtime.to_f, 0.001
        assert_operator result.rows.first.state_file_mtime.to_f, :>, Time.parse(task.fetch("mtime")).to_f
      end
    end
  end

  def test_controller_row_retains_payload_mtime_separately_from_state_file_precision
    with_tmp_dir do |dir|
      folder = File.join(dir, "patrol-fix-controller")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "patrol-fix-manifest.json")
      File.write(state_file, JSON.generate("schema" => "hive-patrol-fix-manifest"))
      state_file_mtime = Time.utc(2026, 8, 25, 0, 10, 48, 584_735)
      File.utime(state_file_mtime, state_file_mtime, state_file)
      payload_mtime = "2026-08-25T00:17:21.900432Z"

      task = task_row(slug: "patrol-fix-controller", mtime: payload_mtime).merge(
        "workflow" => "patrol-fix",
        "folder" => folder,
        "state_file" => state_file
      )
      payload = make_envelope(projects: [ {
        "name" => "hive",
        "path" => dir,
        "hive_state_path" => File.join(dir, ".hive-state"),
        "tasks" => [ task ]
      } ])

      with_status(payload) do |producer|
        result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch

        assert result.ok, "expected ok=true; got error #{result.error.inspect}"
        assert_equal payload_mtime, result.rows.first.status_payload_mtime
        assert_in_delta state_file_mtime.to_f,
                        result.rows.first.state_file_mtime.to_f, 0.001
      end
    end
  end

  # ── failure modes ─────────────────────────────────────────────────────

  def test_producer_failure_preserves_warnings_emitted_before_the_error
    producer = lambda do |task_keys:, warnings:|
      assert_nil task_keys
      warnings << "project demo degraded"
      raise "projection aborted"
    end

    result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch

    refute result.ok
    assert_includes result.error, "RuntimeError: projection aborted"
    assert_includes result.error, "projection warnings: project demo degraded"
  end

  def test_wrong_schema_returns_not_ok
    payload = { "schema" => "hive-something-else", "schema_version" => 1, "ok" => true }
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      refute result.ok
      assert_match(/missing schema=hive-status/, result.error)
    end
  end

  def test_mismatched_schema_version_returns_not_ok
    expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
    payload = make_envelope.merge("schema_version" => expected + 1)

    with_status(payload) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch
      refute result.ok
      assert_match(/schema version must be #{expected}/, result.error)
    end
  end

  def test_extraction_failure_returns_not_ok
    payload = make_envelope(projects: [ 42 ])
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      refute result.ok
      assert_match(/TypeError:/, result.error)
    end
  end

  def test_clean_fetch_has_no_warning
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_row(slug: "exact") ]
    } ])
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      assert result.ok, result.error
      assert_equal [ "exact" ], result.rows.map(&:slug)
      assert_nil result.warning
    end
  end

  def test_successful_fetch_surfaces_projection_warning
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_row(slug: "s1") ]
    } ])
    breadcrumb = "hive: status: dependency resolve failed for \"dep\"; treating as unblocked\n"
    with_status(payload, warning_text: breadcrumb) do |producer|
      result = Hive::Daemon::StatusConsumer.new(producer: producer).fetch
      assert result.ok, result.error
      assert_equal [ "s1" ], result.rows.map(&:slug)
      assert_match(/treating as unblocked/, result.warning)
    end
  end

  def test_envelope_with_ok_false_returns_not_ok
    payload = {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS["hive-status"],
      "ok" => false,
      "error_class" => "ConfigError",
      "message" => "bad config"
    }
    with_status(payload) do |producer|
      consumer = Hive::Daemon::StatusConsumer.new(producer: producer)
      result = consumer.fetch
      refute result.ok
      assert_match(/envelope ok=false/, result.error)
    end
  end
end
