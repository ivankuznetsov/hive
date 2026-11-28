require "test_helper"
require "hive/commands/status"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/approve"
require "hive/commands/stage_action"
require "hive/daemon/status_consumer"
require "hive/dependency_snapshot"
require "hive/operational_status"
require "hive/repository_identity"
require "hive/task_meta"
require "hive/tui/snapshot"
require "hive/tui/views/tasks_pane"
require "hive/web/status_payload"
require "json_schemer"
require_relative "../support/plan_dependency_incident_fixture"

class DependencyAdmissionIntegrationTest < Minitest::Test
  include HiveTestHelper
  include PlanDependencyIncidentFixture

  def test_cross_project_live_repository_mismatch_holds_status_row
    with_tmp_dir do |root|
      app = File.join(root, "app")
      data = File.join(root, "data")
      expected_remote = File.join(root, "expected-data.git")
      wrong_remote = File.join(root, "wrong-data.git")
      [ app, data, expected_remote, wrong_remote ].each { |path| FileUtils.mkdir_p(path) }
      run!("git", "-C", app, "init", "--quiet")
      run!("git", "-C", data, "init", "--quiet")
      run!("git", "-C", data, "remote", "add", "origin", wrong_remote)

      dependent = write_task(app, "4-execute", "dependent-task", "task.md", "EXECUTE_COMPLETE")
      base = write_task(data, "8-finalize", "base-task", "pr.md", "COMPLETE")
      Hive::TaskMeta.write(dependent, id: 2, slug: "dependent-task", display_name: nil,
                                      depends_on: "data:base-task")
      Hive::TaskMeta.write(base, id: 1, slug: "base-task", display_name: nil)

      payload = Hive::Commands::Status.new.json_payload([
        project("app", app, repository_identity: nil),
        project("data", data, repository_identity: Hive::RepositoryIdentity.normalize(expected_remote))
      ])
      row = payload.fetch("projects").first.fetch("tasks").find { |task| task["slug"] == "dependent-task" }

      assert_equal true, row.fetch("blocked")
      assert_equal "admission_error", row.fetch("action")
      assert_nil row.fetch("suggested_command")
      assert_equal "dependency_repository_mismatch", row.fetch("admission_error").fetch("reason_code")
      assert_equal "data:base-task", row.fetch("admission_error").fetch("offending_ref")
    end
  end

  def test_plan_only_ordering_declaration_holds_status_row
    with_tmp_dir do |root|
      prereq = write_task(root, "4-execute", "prerequisite-task", "task.md", "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(prereq, id: 1, slug: "prerequisite-task", display_name: nil)
      folder = write_task(root, "4-execute", "ordering-task", "task.md", "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(folder, id: 2, slug: "ordering-task", display_name: nil)
      File.write(File.join(folder, "plan.md"), "---\ndepends_on: prerequisite-task\n---\n# Plan\n")

      payload = Hive::Commands::Status.new.json_payload([ project(File.basename(root), root) ])
      row = payload.fetch("projects").first.fetch("tasks").find { |task| task["slug"] == "ordering-task" }

      assert_equal true, row.fetch("blocked")
      assert_equal "plan_dependency_missing", row.fetch("admission_error").fetch("reason_code")
    end
  end

  def test_manual_run_and_stage_action_revalidate_plan_only_dependency_before_runner
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(project_name, "prerequisite task", slug_override: "prerequisite-task").call
          Hive::Commands::New.new(project_name, "ordering task", slug_override: "ordering-task").call
        end
        inbox = File.join(dir, ".hive-state", "stages", "1-inbox", "ordering-task")
        execute = File.join(dir, ".hive-state", "stages", "4-execute", "ordering-task")
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "task.md"), "# Task\n<!-- EXECUTE_COMPLETE -->\n")
        File.write(File.join(execute, "plan.md"), "---\ndepends_on: prerequisite-task\n---\n# Plan\n")

        rebase_called = false
        run = Hive::Commands::Run.new(execute, json: true)
        run.define_singleton_method(:perform_rebase) do |*|
          rebase_called = true
          raise "rebase must not run"
        end
        run_out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) { run.call }
        end
        run_payload = JSON.parse(run_out)

        assert_equal false, rebase_called
        assert_equal "admission_error", run_payload.fetch("error_kind")
        assert_equal "plan_dependency_missing", run_payload.fetch("reason_code")
        assert_equal Hive::ExitCodes::CONFIG, run_payload.fetch("exit_code")
        assert_schema_valid("hive-run", run_payload)

        action_out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) do
            Hive::Commands::StageAction.new("develop", execute, json: true).call
          end
        end
        action_payload = JSON.parse(action_out)
        assert_equal "admission_error", action_payload.fetch("error_kind")
        assert_equal "plan_dependency_missing", action_payload.fetch("reason_code")
        assert_schema_valid("hive-stage-action", action_payload)
        assert File.directory?(execute), "held task must not be moved"
      end
    end
  end

  def test_forward_approve_returns_retryable_wait_and_force_cannot_bypass_it
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(project_name, "base task", slug_override: "base-task").call
          Hive::Commands::New.new(
            project_name,
            "dependent task",
            slug_override: "dependent-task",
            depends_on: "base-task"
          ).call
        end
        inbox = File.join(dir, ".hive-state", "stages", "1-inbox", "dependent-task")
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", "dependent-task")
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "# Done\n<!-- COMPLETE -->\n")
        head_before = run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip

        out, = capture_io do
          assert_raises(Hive::DependencyWaitError) do
            Hive::Commands::Approve.new(brainstorm, force: true, json: true).call
          end
        end
        payload = JSON.parse(out)

        assert_equal "dependency_wait", payload.fetch("error_kind")
        assert_equal "dependency_wait", payload.fetch("reason_code")
        assert_equal "base-task", payload.fetch("offending_ref")
        assert_equal Hive::ExitCodes::TEMPFAIL, payload.fetch("exit_code")
        assert_schema_valid("hive-approve", payload)
        assert File.directory?(brainstorm)
        refute File.exist?(File.join(dir, ".hive-state", "stages", "3-plan", "dependent-task"))
        assert_equal head_before,
                     run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip
      end
    end
  end

  def test_nine_way_fan_in_uses_done_gate_while_scalar_keeps_configured_gate
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        config_path = File.join(dir, ".hive-state", "config.yml")
        config = YAML.safe_load(File.read(config_path))
        File.write(config_path, config.merge("dependency_gate_stage" => "8-finalize").to_yaml)

        prerequisites = (1..9).map { |index| "prerequisite-#{index}" }
        capture_io do
          prerequisites.each do |slug|
            Hive::Commands::New.new(project_name, slug, slug_override: slug).call
          end
          Hive::Commands::New.new(
            project_name,
            "scalar dependent",
            slug_override: "scalar-dependent",
            depends_on: prerequisites.first
          ).call
          Hive::Commands::New.new(
            project_name,
            "fan in dependent",
            slug_override: "fan-in-dependent",
            depends_on: prerequisites
          ).call
        end

        stages = File.join(dir, ".hive-state", "stages")
        prerequisites.each do |slug|
          FileUtils.mv(
            File.join(stages, "1-inbox", slug),
            File.join(stages, "8-finalize", slug)
          )
        end
        %w[scalar-dependent fan-in-dependent].each do |slug|
          folder = File.join(stages, "2-brainstorm", slug)
          FileUtils.mv(File.join(stages, "1-inbox", slug), folder)
          File.write(File.join(folder, "brainstorm.md"), "# Done\n<!-- COMPLETE -->\n")
        end

        context = Hive::DependencySnapshot.admission_context
        scalar = context.verdict(project: project_name, slug: "scalar-dependent")
        fan_in = context.verdict(project: project_name, slug: "fan-in-dependent")

        assert scalar.clear?, "a scalar edge must retain the configured 8-finalize gate"
        assert fan_in.wait?
        assert_nil fan_in.blocked_by
        assert_nil fan_in.dependency_stage
        assert_equal prerequisites.map { |slug| [ slug, slug, "8-finalize", "9-done" ] },
                     fan_in.unmet_dependencies.map { |unmet|
                       [ unmet.reference, unmet.blocked_by, unmet.dependency_stage, unmet.required_gate ]
                     }

        scalar_folder = File.join(stages, "2-brainstorm", "scalar-dependent")
        capture_io { Hive::Commands::Approve.new(scalar_folder, force: true).call }
        assert File.directory?(File.join(stages, "3-plan", "scalar-dependent"))

        fan_in_folder = File.join(stages, "2-brainstorm", "fan-in-dependent")
        head_before = run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip
        out, = capture_io do
          assert_raises(Hive::DependencyWaitError) do
            Hive::Commands::Approve.new(fan_in_folder, force: true, json: true).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "dependency_wait", payload.fetch("reason_code")
        assert_equal prerequisites.first, payload.fetch("offending_ref")
        prerequisites.each do |slug|
          assert_includes payload.fetch("safe_correction"), slug
        end
        assert File.directory?(fan_in_folder), "--force must not bypass dependency admission"
        assert_equal head_before,
                     run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip

        prerequisites.first(3).each do |slug|
          FileUtils.mv(
            File.join(stages, "8-finalize", slug),
            File.join(stages, "9-done", slug)
          )
        end
        remaining = Hive::DependencySnapshot.admission_context
          .verdict(project: project_name, slug: "fan-in-dependent")
        assert_equal prerequisites.drop(3), remaining.unmet_dependencies.map(&:blocked_by)
        assert_equal [ "9-done" ] * 6, remaining.unmet_dependencies.map(&:required_gate)

        prerequisites.drop(3).each do |slug|
          FileUtils.mv(
            File.join(stages, "8-finalize", slug),
            File.join(stages, "9-done", slug)
          )
        end
        assert Hive::DependencySnapshot.admission_context
          .verdict(project: project_name, slug: "fan-in-dependent").clear?

        capture_io { Hive::Commands::Approve.new(fan_in_folder, force: true).call }
        assert File.directory?(File.join(stages, "3-plan", "fan-in-dependent"))
      end
    end
  end

  def test_forward_approve_rejects_missing_dependency_but_backward_recovery_skips_admission
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(
            project_name,
            "held task",
            slug_override: "held-task",
            depends_on: "missing-task"
          ).call
        end
        inbox = File.join(dir, ".hive-state", "stages", "1-inbox", "held-task")
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", "held-task")
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "# Done\n<!-- COMPLETE -->\n")

        out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) do
            Hive::Commands::Approve.new(brainstorm, force: true, json: true).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "dependency_task_missing", payload.fetch("reason_code")
        assert File.directory?(brainstorm)

        execute = File.join(dir, ".hive-state", "stages", "4-execute", "held-task")
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(brainstorm, execute)
        File.write(File.join(execute, "plan.md"), "---\ndepends_on: [broken\n---\n")
        capture_io { Hive::Commands::Approve.new(execute, to: "3-plan").call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", "held-task")),
               "backward recovery must remain possible with corrupt admission metadata"
      end
    end
  end

  def test_manual_run_rejects_cross_project_repository_mismatch
    with_tmp_global_config do
      with_tmp_dir do |root|
        app = File.join(root, "app")
        data = File.join(root, "data")
        expected = File.join(root, "expected-data.git")
        wrong = File.join(root, "wrong-data.git")
        [ app, data, expected, wrong ].each { |path| FileUtils.mkdir_p(path) }
        [ app, data ].each { |path| initialize_git_repo(path) }
        run!("git", "-C", data, "remote", "add", "origin", expected)
        capture_io do
          Hive::Commands::Init.new(app).call
          Hive::Commands::Init.new(data).call
          Hive::Commands::New.new("data", "base", slug_override: "base-task").call
          Hive::Commands::New.new(
            "app", "dependent", slug_override: "dependent-task", depends_on: "data:base-task"
          ).call
        end
        run!("git", "-C", data, "remote", "set-url", "origin", wrong)
        inbox = File.join(app, ".hive-state", "stages", "1-inbox", "dependent-task")
        execute = File.join(app, ".hive-state", "stages", "4-execute", "dependent-task")
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "task.md"), "# Task\n")

        out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) do
            Hive::Commands::Run.new(execute, json: true).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "dependency_repository_mismatch", payload.fetch("reason_code")
        assert_equal "data:base-task", payload.fetch("offending_ref")
        assert File.directory?(execute)
      end
    end
  end

  def test_inherited_root_defect_raises_wait_error_and_leaves_descendant_files_untouched
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(project_name, "c5 root", slug_override: "c5-root").call
          Hive::Commands::New.new(project_name, "c6 direct", slug_override: "c6-direct",
                                  depends_on: "c5-root").call
          Hive::Commands::New.new(project_name, "c7 transitive", slug_override: "c7-transitive",
                                  depends_on: "c6-direct").call
        end
        stages = File.join(dir, ".hive-state", "stages")
        c5 = File.join(stages, "3-plan", "c5-root")
        c6 = File.join(stages, "2-brainstorm", "c6-direct")
        c7 = File.join(stages, "2-brainstorm", "c7-transitive")
        FileUtils.mkdir_p(File.dirname(c5))
        FileUtils.mkdir_p(File.dirname(c6))
        FileUtils.mv(File.join(stages, "1-inbox", "c5-root"), c5)
        FileUtils.mv(File.join(stages, "1-inbox", "c6-direct"), c6)
        FileUtils.mv(File.join(stages, "1-inbox", "c7-transitive"), c7)
        File.write(File.join(c5, "plan.md"), "---\ndepends_on:\n  - F2\n  - F3\n---\n# Broken\n")
        File.write(File.join(c6, "brainstorm.md"), "# Direct\n<!-- COMPLETE -->\n")
        File.write(File.join(c7, "brainstorm.md"), "# Transitive\n<!-- COMPLETE -->\n")
        # Persisted legacy descendant repair artifact must remain untouched by read-only checks.
        legacy_repair = File.join(c6, "diagnostics", "red-status.md")
        FileUtils.mkdir_p(File.dirname(legacy_repair))
        File.write(legacy_repair, "# Legacy descendant repair note\n")

        c6_meta_before = File.binread(File.join(c6, "meta.yml"))
        c7_meta_before = File.binread(File.join(c7, "meta.yml"))
        legacy_before = File.binread(legacy_repair)

        root_err = assert_raises(Hive::DependencyAdmissionError) do
          Hive::Commands::Run.new(c5, quiet: true).call
        end
        assert_equal "plan_dependency_invalid", root_err.reason_code

        c6_out, = capture_io do
          assert_raises(Hive::DependencyWaitError) do
            Hive::Commands::Approve.new(c6, force: true, json: true).call
          end
        end
        c6_payload = JSON.parse(c6_out)
        assert_equal "dependency_wait", c6_payload.fetch("error_kind")
        assert_equal "dependency_wait", c6_payload.fetch("reason_code")
        assert_equal "#{project_name}:c5-root", c6_payload.fetch("offending_ref")
        assert_includes c6_payload.fetch("message"), "#{project_name}:c5-root: invalid depends_on F2, F3"
        assert_schema_valid("hive-approve", c6_payload)

        c7_out, = capture_io do
          assert_raises(Hive::DependencyWaitError) do
            Hive::Commands::Run.new(c7, json: true).call
          end
        end
        c7_payload = JSON.parse(c7_out)
        assert_equal "dependency_wait", c7_payload.fetch("error_kind")
        assert_equal "#{project_name}:c5-root", c7_payload.fetch("offending_ref")
        assert_schema_valid("hive-run", c7_payload)

        assert_equal c6_meta_before, File.binread(File.join(c6, "meta.yml"))
        assert_equal c7_meta_before, File.binread(File.join(c7, "meta.yml"))
        assert_equal legacy_before, File.binread(legacy_repair)
      end
    end
  end

  def test_end_to_end_root_repair_clears_inherited_surfaces_while_retaining_siblings_and_legacy_records
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        create_done_prerequisite(dir, slug: "f2-payments-261030-aaaa", id: 2,
                                      idempotency_key: "#{project_name}:F2:v1")
        create_done_prerequisite(dir, slug: "f3-ledger-261030-bbbb", id: 3,
                                      idempotency_key: "#{project_name}:F3:v1")
        capture_io do
          Hive::Commands::New.new(project_name, "waiting sibling", slug_override: "waiting-sibling").call
          Hive::Commands::New.new(project_name, "c5 root", slug_override: "c5-root").call
          Hive::Commands::New.new(project_name, "c6 direct", slug_override: "c6-direct",
                                  depends_on: "c5-root").call
          Hive::Commands::New.new(project_name, "c7 fanin", slug_override: "c7-fanin",
                                  depends_on: %w[c6-direct waiting-sibling]).call
        end
        sibling = move_stage_task(dir, "waiting-sibling", from: "1-inbox", to: "2-brainstorm")
        c5 = move_stage_task(dir, "c5-root", from: "1-inbox", to: "3-plan")
        c6 = move_stage_task(dir, "c6-direct", from: "1-inbox", to: "2-brainstorm")
        c7 = move_stage_task(dir, "c7-fanin", from: "1-inbox", to: "2-brainstorm")
        File.write(File.join(sibling, "brainstorm.md"), "# Sibling\n<!-- WAITING -->\n")
        File.write(File.join(c5, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")
        File.write(File.join(c5, "plan.md"), incident_plan_markdown(depends_on: %w[F2 F3], low_risk: true))
        File.write(File.join(c6, "brainstorm.md"), "# Direct\n<!-- COMPLETE -->\n")
        File.write(File.join(c7, "brainstorm.md"), "# Fanin\n<!-- COMPLETE -->\n")

        legacy_repair = File.join(c6, "diagnostics", "red-status.md")
        FileUtils.mkdir_p(File.dirname(legacy_repair))
        File.write(legacy_repair, "# Legacy descendant repair record\n")
        historical_review = File.join(c5, "plan-review", "reviews", "pr-historical", "manifest.json")
        FileUtils.mkdir_p(File.dirname(historical_review))
        File.write(historical_review, "{\"review_id\":\"pr-historical\"}\n")

        legacy_before = File.binread(legacy_repair)
        historical_before = File.binread(historical_review)
        c6_meta_before = File.binread(File.join(c6, "meta.yml"))
        c7_meta_before = File.binread(File.join(c7, "meta.yml"))

        # Read-only status, operational, daemon consumer, TUI, and web surfaces before repair
        before_json = Hive::Commands::Status.new(json: true).json_payload(Hive::Config.registered_projects)
        before_by_slug = before_json.fetch("projects").first.fetch("tasks").to_h { |t| [ t["slug"], t ] }
        assert_equal "admission_error", before_by_slug["c5-root"]["action"]
        assert_equal "plan_dependency_invalid", before_by_slug["c5-root"].dig("admission_error", "reason_code")
        assert_nil before_by_slug["c6-direct"]["admission_error"]
        assert_equal [ "c5-root" ], before_by_slug["c6-direct"]["dependency_repair_roots"].map { |r| r["slug"] }
        assert_equal [ "c5-root" ], before_by_slug["c7-fanin"]["dependency_repair_roots"].map { |r| r["slug"] }
        assert_includes before_by_slug["c7-fanin"]["unmet_dependencies"].map { |u| u["blocked_by"] }, "waiting-sibling"

        before_op = Hive::OperationalStatus.new(
          status_payload: before_json,
          project_context: { project_name => { "daemon_enabled" => false } }
        ).to_h
        before_c7_op = before_op.fetch("tasks").find { |t| t.dig("identity", "slug") == "c7-fanin" }
        assert_equal "waiting_on_provider_or_scheduler", before_c7_op["state"]
        assert_includes before_c7_op["reason"], "#{project_name}:c5-root: invalid depends_on F2, F3"
        assert_includes before_c7_op["reason"], "waiting-sibling"

        consumer_before = Hive::Daemon::StatusConsumer.new(
          producer: ->(task_keys:, warnings:) { before_json }
        ).fetch
        assert consumer_before.ok
        c6_consumer = consumer_before.rows.find { |r| r.slug == "c6-direct" }
        assert_equal [ "c5-root" ], c6_consumer.dependency_repair_roots.map { |r| r["slug"] }
        assert_nil c6_consumer.admission_error

        tui_before = Hive::Tui::Snapshot.from_payload(before_json).rows.to_h { |r| [ r.slug, r ] }
        assert_includes Hive::Tui::Views::TasksPane.status_label(tui_before["c6-direct"]),
                        "#{project_name}:c5-root: invalid depends_on F2, F3"
        web_before = Hive::Web::StatusPayload.call(before_json)
        web_c6 = web_before.fetch("projects").first.fetch("tasks").find { |t| t["slug"] == "c6-direct" }
        assert_equal [ "c5-root" ], web_c6["dependency_repair_roots"].map { |r| r["slug"] }

        # Repair ONLY the root via explicit `hive plan c5-root --project <p> --from 3-plan`
        fixed_plan = incident_plan_markdown(
          depends_on: %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb], low_risk: true
        )
        fake_agent = lambda do |_task, _cfg, _prompt, _profile, **|
          File.write(File.join(c5, "plan.md"), fixed_plan)
          { exit_code: 0, model: "claude-opus-4-6" }
        end
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, fake_agent) do
          capture_io do
            Hive::Commands::StageAction.new("plan", "c5-root", project: project_name, from: "3-plan").call
          end
        end

        # After repair: inherited evidence clears across every surface; waiting siblings and ordinary gates stay.
        after_json = Hive::Commands::Status.new(json: true).json_payload(Hive::Config.registered_projects)
        after_by_slug = after_json.fetch("projects").first.fetch("tasks").to_h { |t| [ t["slug"], t ] }
        refute after_by_slug["c5-root"]["blocked"]
        assert_nil after_by_slug["c5-root"]["admission_error"]
        assert_equal %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb], after_by_slug["c5-root"]["depends_on"]
        refute after_by_slug["c6-direct"].key?("dependency_repair_roots")
        assert_equal true, after_by_slug["c6-direct"]["blocked"]
        assert_equal "c5-root", after_by_slug["c6-direct"]["blocked_by"]
        refute after_by_slug["c7-fanin"].key?("dependency_repair_roots")
        assert_equal %w[c6-direct waiting-sibling],
                     after_by_slug["c7-fanin"]["unmet_dependencies"].map { |u| u["blocked_by"] }

        after_op = Hive::OperationalStatus.new(
          status_payload: after_json,
          project_context: { project_name => { "daemon_enabled" => false } }
        ).to_h
        after_c6_op = after_op.fetch("tasks").find { |t| t.dig("identity", "slug") == "c6-direct" }
        refute_includes after_c6_op["reason"], "invalid depends_on"
        assert_includes after_c6_op["reason"], "c5-root (3-plan)"

        tui_after = Hive::Tui::Snapshot.from_payload(after_json).rows.to_h { |r| [ r.slug, r ] }
        assert_empty tui_after["c6-direct"].dependency_repair_roots
        assert_includes Hive::Tui::Views::TasksPane.status_label(tui_after["c6-direct"]), "c5-root (3-plan)"
        web_after = Hive::Web::StatusPayload.call(after_json)
        refute web_after.fetch("projects").first.fetch("tasks").find { |t| t["slug"] == "c6-direct" }
          .key?("dependency_repair_roots")

        # Read-only status and root repair never touch descendants, persisted legacy repair, or historical reviews.
        assert_equal c6_meta_before, File.binread(File.join(c6, "meta.yml"))
        assert_equal c7_meta_before, File.binread(File.join(c7, "meta.yml"))
        assert_equal legacy_before, File.binread(legacy_repair)
        assert_equal historical_before, File.binread(historical_review)
      end
    end
  end

  private

  def assert_schema_valid(name, payload)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    errors = schemer.validate(payload).to_a
    assert_empty errors, "#{name} payload did not validate: #{errors.inspect}"
  end

  def initialize_git_repo(path)
    run!("git", "-C", path, "init", "-b", "master", "--quiet")
    run!("git", "-C", path, "config", "user.email", "test@example.com")
    run!("git", "-C", path, "config", "user.name", "Test")
    run!("git", "-C", path, "config", "commit.gpgsign", "false")
    File.write(File.join(path, "README.md"), "test\n")
    run!("git", "-C", path, "add", ".")
    run!("git", "-C", path, "commit", "-m", "initial", "--quiet")
  end

  def project(name, root, repository_identity: nil)
    {
      "name" => name,
      "path" => root,
      "hive_state_path" => File.join(root, ".hive-state"),
      "repository_identity" => repository_identity
    }
  end

  def write_task(root, stage, slug, state_file, marker)
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, state_file), "<!-- #{marker} -->\n")
    folder
  end
end
