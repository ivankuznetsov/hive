require "test_helper"
require "json_schemer"
require "hive/commands/status"
require "hive/commands/review_grant"
require_relative "../../support/review_grant_fixture"

class CommandsStatusOperationalTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  def test_review_grant_is_visible_without_scheduler_recovery_and_never_executable_by_act
    with_review_grant_task do |task, _cfg|
      command = Hive::Commands::Status.new(json: true, operational: true)
      project = { "name" => task.project_name, "path" => task.project_root, "hive_state_path" => task.hive_state_path }
      before = Dir[File.join(task.folder, "**", "*")].select { |p| File.file?(p) }.to_h { |p| [ p, File.binread(p) ] }
      payload = command.operational_payload([ project ])
      row = payload.fetch("tasks").find { |r| r.dig("identity", "slug") == task.slug }
      grant = row.fetch("review_grant")
      assert_equal "eligible", grant.fetch("state")
      assert_equal "workflow.grant_fix_passes", grant.dig("action", "action_id")
      refute_includes Hive::OperationalAction::EXECUTABLE_ACTION_IDS, grant.dig("action", "action_id")
      assert_includes grant.fetch("command"), "hive review-grant #{task.slug}"
      assert_includes grant.fetch("command"), "--passes N --reason TEXT --evidence-token"
      assert_match(/\A[0-9a-f]{64}\z/, grant.fetch("evidence_token"))
      assert_equal "operator", row.fetch("blocker_owner")
      assert_equal before, before.keys.to_h { |p| [ p, File.binread(p) ] }
      refute File.exist?(File.join(task.folder, "review-budget"))
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))
      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
      output, = capture_io { command.send(:render_operational, payload) }
      assert_includes output, grant.fetch("command")
    end
  end

  def test_applied_and_suspended_review_budget_remains_visible_without_recovery_payload
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      capture_io do
        Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
          passes: "3", reason: "Complete the accepted fixes", evidence_token: budget.observe.evidence_token).call
      end
      project = { "name" => task.project_name, "path" => task.project_root, "hive_state_path" => task.hive_state_path }
      command = Hive::Commands::Status.new(operational: true)
      applied = command.operational_payload([ project ]).fetch("tasks").first.fetch("review_grant")
      assert_equal "applied", applied.fetch("state")
      assert_equal 3, applied.fetch("remaining")
      output, = capture_io { command.send(:render_operational, command.operational_payload([ project ])) }
      assert_includes output, "review grant applied: 3 fix pass(es) remaining"
      assert_includes output, "Normal review admission and existing recovery holds apply."
      refute_includes output, "--evidence-token"
      Hive::Markers.set(task.state_file, :review_error, phase: "fix", reason: "limits_reached", pass: 4)
      suspended = command.operational_payload([ project ]).fetch("tasks").first.fetch("review_grant")
      assert_equal "suspended", suspended.fetch("state")
      assert_equal 3, suspended.fetch("remaining")
      assert_equal "review_error", suspended.dig("blocking_marker", "name")
      refute suspended.key?("evidence_token")
      refute suspended.key?("action")
      output, = capture_io { command.send(:render_operational, command.operational_payload([ project ])) }
      assert_includes output, "review grant suspended: 3 fix pass(es) remaining"
      assert_includes output, "Use the existing recovery route for review_error"
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))
      assert schema.valid?(command.operational_payload([ project ]))
    end
  end

  def test_insufficient_grant_evidence_has_specific_diagnostic_and_no_token
    with_review_grant_task do |task, _cfg|
      File.delete(File.join(task.folder, "reviews", "fix-success-03.md"))
      project = { "name" => task.project_name, "path" => task.project_root, "hive_state_path" => task.hive_state_path }
      command = Hive::Commands::Status.new(operational: true)
      row = command.operational_payload([ project ]).fetch("tasks").first
      assert_nil row.fetch("review_grant")
      assert_match(/fix-success-03/, row.dig("evidence", "review_grant_diagnostic", "remediation"))
      output, = capture_io { command.send(:render_operational, command.operational_payload([ project ])) }
      assert_includes output, "fix-success-03"
      refute_includes output, "--evidence-token"
    end
  end

  def teardown
    Hive::RuntimeControlPlane::OperationalInspection.clear! if
      defined?(Hive::RuntimeControlPlane::OperationalInspection)
    super
  end

  def test_operational_text_renders_publication_commands_and_retained_commit_evidence
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      folder = File.join(state, "stages", "6-review", "fix-261101-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "# Fix\n")
      Hive::Markers.set(File.join(folder, "task.md"), :review_error, reason: "review_publication_failed",
        **Hive::ReviewPublicationRecovery.encode("publication" => "unpublished", "verification" => "pending",
          "worktree" => "/owned/a b", "branch" => "fix", "unpushed_shas" => [ "a" * 40 ],
          "push_command" => "cd /owned/a\\ b && git push origin HEAD:fix"))
      command = Hive::Commands::Status.new(operational: true)
      payload = command.operational_payload([ { "name" => "demo", "path" => project_root, "hive_state_path" => state } ])
      output, = capture_io { command.render_operational(payload) }
      assert_includes output, "Publication: unpublished"
      assert_includes output, "Worktree: /owned/a b"
      assert_includes output, "a" * 40
      assert_includes output, "git push origin HEAD:fix"
    end
  end

  def test_operational_payload_is_additive_and_keeps_current_status_v9_unchanged
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "2-brainstorm", "ready-260720-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      command = Hive::Commands::Status.new(json: true, operational: true)

      legacy = command.json_payload([ project ])
      operational = command.operational_payload([ project ])

      assert_equal "hive-status", legacy.fetch("schema")
      assert_equal 9, legacy.fetch("schema_version")
      assert_equal "hive-operational-status", operational.fetch("schema")
      assert_equal [ "ready-260720-abcd" ], legacy.dig("projects", 0, "tasks").map { |row| row.fetch("slug") }
      assert_equal [ "ready-260720-abcd" ], operational.fetch("tasks").map { |row| row.dig("identity", "slug") }
      refute operational.fetch("tasks").first.fetch("evidence").key?("suggested_command")
    end
  end

  def test_operational_json_call_emits_the_operational_envelope
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      FileUtils.mkdir_p(File.join(hive_state, "stages"))

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
        stdout, = capture_io { Hive::Commands::Status.new(json: true, operational: true).call }
        payload = JSON.parse(stdout)
        schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))

        assert_equal "hive-operational-status", payload.fetch("schema")
        assert schema.valid?(payload), schema.validate(payload).map { |error| error.fetch("error") }.inspect
      end
    end
  end

  def test_inspection_context_carries_through_uncached_operational_task_and_attempt_reads
    with_tmp_global_config do |state_home|
      with_tmp_dir do |project_root|
        hive_state = File.join(project_root, ".hive-state")
        slug = "read-only-audit-261003-abcd"
        folder = File.join(hive_state, "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
        project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
        database = Struct.new(:path) do
          def confirmed_read_only_storage? = true
        end.new(Hive::Paths.runtime_control_plane_path(state_home))
        error = Hive::RuntimeControlPlane::Unavailable.new(
          "read only", code: :state_storage_read_only,
          action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
        )
        assert Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
          error: error, argv: %w[status --operational --json], state_home: state_home,
          database: database
        )

        with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
          stdout, = capture_io { Hive::Commands::Status.new(json: true, operational: true).call }
          payload = JSON.parse(stdout)
          assert_equal true, payload.fetch("ok")
          assert_equal [ slug ], payload.fetch("tasks").map { |row| row.dig("identity", "slug") }
        end
      end
    end
  end

  def test_operational_recoveries_uses_the_same_canonical_recovery_projection
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-review", "failed-260725-abcd")
      FileUtils.mkdir_p(folder)
      File.write(
        File.join(folder, "review.md"),
        <<~MARKDOWN
          # Review
          <!-- REVIEW_ERROR marker_id=recovery-1 reason=review_failed phase=review pass=1 -->
        MARKDOWN
      )
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      command = Hive::Commands::Status.new(json: true)
      source = command.json_payload([ project ])

      full = command.operational_payload(
        [ project ],
        status_payload: source,
        scheduler_snapshot: nil
      )
      lean = command.operational_recoveries(
        [ project ],
        status_payload: source,
        scheduler_snapshot: nil
      )

      expected = full.fetch("tasks").filter_map do |row|
        next unless row["recovery"]

        {
          "identity" => row.fetch("identity").slice("project", "slug"),
          "recovery" => row.fetch("recovery")
        }
      end
      assert_equal expected, lean
    end
  end

  def test_supplied_status_payload_skips_workflow_generation_capture
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      File.write(
        File.join(hive_state, "config.yml"),
        { "daemon" => { "enabled" => true } }.to_yaml
      )
      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      command = Hive::Commands::Status.new(json: true)
      source = command.json_payload([ project ])
      command.define_singleton_method(:capture_workflow_generations) do |_projects|
        raise "supplied payload must not trigger generation capture"
      end
      original_load = Hive::Config.method(:load)
      config_loads = 0

      payload = with_replaced_singleton_method(
        Hive::Config,
        :load,
        lambda do |path|
          config_loads += 1
          original_load.call(path)
        end
      ) do
        command.operational_payload(
          [ project ], status_payload: source, scheduler_snapshot: nil
        )
      end

      assert_equal "unavailable", payload.dig("scheduler", "status")
      assert_equal 1, config_loads
    end
  end

  def test_operational_call_uses_its_own_error_schema
    command = Hive::Commands::Status.new(json: true, operational: true)

    assert_equal "hive-operational-status", command.status_schema_for_call
    assert_equal "hive-running-status", Hive::Commands::Status.new(json: true).status_schema_for_call
  end

  def test_operational_storage_error_exposes_code_and_next_action_additively
    command = Hive::Commands::Status.new(json: true, operational: true)
    error = Hive::RuntimeControlPlane::Unavailable.new(
      "Hive state is mounted read-only",
      code: :state_storage_read_only,
      action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
    )
    command.define_singleton_method(:do_call) { raise error }

    stdout, _stderr, status = with_captured_exit { command.call }
    payload = JSON.parse(stdout)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))

    assert_equal Hive::ExitCodes::UNAVAILABLE, status
    assert_equal false, payload.fetch("ok")
    assert_equal "state_storage_read_only", payload.fetch("code")
    assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION,
                 payload.fetch("next_action")
    assert schema.valid?(payload), schema.validate(payload).map { |entry| entry.fetch("error") }.inspect
  end

  def test_storage_extras_do_not_leak_to_other_status_error_schemas
    error = Hive::RuntimeControlPlane::Unavailable.new(
      "Hive state is mounted read-only",
      code: :state_storage_read_only,
      action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
    )
    cases = [
      [ Hive::Commands::Status.new(json: true), "hive-running-status" ],
      [ Hive::Commands::Status.new(json: true, full: true), "hive-status" ],
      [ Hive::Commands::Status.new(json: true, archive: true), "hive-status" ],
      [ Hive::Commands::Status.new(json: true, daemon_tasks: [ "demo:task" ], full: true), "hive-status" ],
      [ Hive::Commands::Status.new(json: true, diagnose: "task"), "hive-status-diagnose" ]
    ]

    cases.each do |command, schema_name|
      command.define_singleton_method(:do_call) { raise error }
      command.define_singleton_method(:diagnose_call) { raise error }
      stdout, _stderr, status = with_captured_exit { command.call }
      payload = JSON.parse(stdout)
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema_name))))

      assert_equal Hive::ExitCodes::UNAVAILABLE, status, schema_name
      refute payload.key?("code"), schema_name
      refute payload.key?("next_action"), schema_name
      assert schema.valid?(payload),
             "#{schema_name}: #{schema.validate(payload).map { |entry| entry.fetch('error') }.inspect}"
    end
  end

  def test_degraded_attempt_storage_renders_one_concise_warning
    issue = {
      "code" => "attempt_storage_degraded",
      "message" => "attempt storage is degraded: maintenance failed",
      "remediation" => "inspect the daemon log, then retry the failed storage operation"
    }

    out, = capture_io do
      Hive::Commands::Status.new.send(:render_operational_issues, [ issue ])
    end

    assert_equal 1, out.lines.size
    assert_includes out, "maintenance failed"
    assert_includes out, "inspect the daemon log"
  end
end
