require "test_helper"
require "erb"
require "fileutils"
require "json"
require "json_schemer"
require "tmpdir"
require "yaml"
require "hive/commands/stack"
require "hive/commands/status"
require "hive/commands/task"
require "hive/daemon/dispatcher"
require "hive/daemon/operational_snapshot"
require "hive/daemon/policy"
require "hive/daemon/status_consumer"
require "hive/operational_status"
require "hive/task_meta"
require "hive/task_workspace/dependency_component"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/red_status_detail"
require "hive/tui/views/tasks_pane"
require "hive/web/status_payload"

class DependencyRepairSurfacesTest < Minitest::Test
  include HiveTestHelper

  REPO_IDENTITY = "github.com/acme/app".freeze

  def with_incident_graph
    Dir.mktmpdir("hive-u4-surfaces-") do |root|
      FileUtils.mkdir_p(File.join(root, ".hive-state", "stages", "3-plan"))
      prepare_test_runtime_project(root)
      File.write(
        File.join(root, ".hive-state", "config.yml"),
        YAML.dump("plan_review" => { "enabled" => true }, "rebase" => { "enabled" => false })
      )

      # Seed unique hint candidates for F2, F3, C4
      seed_task(root, "f2-payments-261030-aaaa", stage: "9-done", id: 1)
      seed_task(root, "f3-ledger-261030-bbbb", stage: "9-done", id: 2)
      seed_task(root, "c4-auth-261030-cccc", stage: "9-done", id: 3)
      seed_task(root, "waiting-sibling", stage: "4-execute", id: 4)

      # Root 1: C5 with invalid list [F2, F3]
      c5 = seed_task(
        root, "c5-root", stage: "3-plan", id: 5,
        plan_content: "---\ndepends_on:\n  - F2\n  - F3\n---\n# C5\n<!-- WAITING -->\n"
      )
      # Root 2: C8 with invalid scalar C4
      c8 = seed_task(
        root, "c8-root", stage: "3-plan", id: 8,
        plan_content: "---\ndepends_on: C4\n---\n# C8\n<!-- WAITING -->\n"
      )
      # Direct descendant C6 -> C5
      c6 = seed_task(
        root, "c6-direct", stage: "2-brainstorm", id: 6,
        depends_on: "c5-root",
        state_content: "# C6\n<!-- COMPLETE -->\n"
      )
      # Multi-root + waiting sibling descendant C7 -> [waiting-sibling, c6-direct, c8-root]
      c7 = seed_task(
        root, "c7-fanin", stage: "2-brainstorm", id: 7,
        depends_on: %w[waiting-sibling c6-direct c8-root],
        state_content: "# C7\n<!-- COMPLETE -->\n"
      )
      # Independently broken descendant C9 -> C5 with own invalid F9
      c9 = seed_task(
        root, "c9-own-defect", stage: "3-plan", id: 9,
        depends_on: "c5-root",
        plan_content: "---\ndepends_on: F9\n---\n# C9\n<!-- WAITING -->\n"
      )

      registry = [
        {
          "name" => "app",
          "path" => root,
          "hive_state_path" => File.join(root, ".hive-state"),
          "repository_identity" => REPO_IDENTITY
        }
      ]
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { registry }) do
        with_replaced_singleton_method(Hive::RepositoryIdentity, :current, ->(_) { REPO_IDENTITY }) do
          yield root, registry, { c5: c5, c6: c6, c7: c7, c8: c8, c9: c9 }
        end
      end
    end
  end

  def seed_task(root, slug, stage:, id:, depends_on: nil, plan_content: nil, state_content: nil)
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(
      folder, id: id, slug: slug, display_name: slug, workflow: "coding", depends_on: depends_on
    )
    File.write(File.join(folder, "plan.md"), plan_content) if plan_content
    if state_content
      filename = stage == "2-brainstorm" ? "brainstorm.md" : "task.md"
      File.write(File.join(folder, filename), state_content)
    end
    Hive::Task.new(folder)
  end

  def validate_schema!(name, payload)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    errors = schemer.validate(payload).to_a
    assert_empty errors, "#{name} schema rejected payload: #{errors.inspect}"
  end

  def test_status_json_text_operational_status_and_status_consumer_round_trip
    with_incident_graph do |_root, registry, tasks|
      status_cmd = Hive::Commands::Status.new(json: true)
      payload = status_cmd.json_payload(registry)
      validate_schema!("hive-status", payload)

      by_slug = payload.fetch("projects").first.fetch("tasks").to_h { |t| [ t["slug"], t ] }

      # C5 local root: admission_error present, no inherited dependency_repair_roots key
      c5_row = by_slug.fetch("c5-root")
      assert_equal "admission_error", c5_row["action"]
      assert_equal "plan_dependency_invalid", c5_row.dig("admission_error", "reason_code")
      assert_equal "F2, F3", c5_row.dig("admission_error", "offending_ref")
      refute c5_row.key?("dependency_repair_roots")

      # C6 direct descendant: ordinary wait (no admission_error), carries C5 repair root with indexed hints
      c6_row = by_slug.fetch("c6-direct")
      assert_equal true, c6_row["blocked"]
      assert_nil c6_row["admission_error"]
      refute_equal "admission_error", c6_row["action"]
      assert_equal 1, c6_row["dependency_repair_roots"].length
      root_ev = c6_row["dependency_repair_roots"].first
      assert_equal "app", root_ev["project"]
      assert_equal "c5-root", root_ev["slug"]
      assert_equal "F2, F3", root_ev["offending_ref"]
      assert_equal [ 0, 1 ], root_ev["issues"].map { |i| i["index"] }
      assert_equal %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb],
                   root_ev["issues"].map { |i| i["suggestion"] }
      assert_includes root_ev["safe_correction"], "hive plan c5-root --project app --from 3-plan"

      # C7 multi-root + waiting sibling: stable root order [c5-root, c8-root], preserves waiting-sibling
      c7_row = by_slug.fetch("c7-fanin")
      assert_equal true, c7_row["blocked"]
      assert_nil c7_row["admission_error"]
      assert_nil c7_row["blocked_by"]
      assert_equal %w[c5-root c8-root], c7_row["dependency_repair_roots"].map { |r| r["slug"] }
      assert_equal %w[waiting-sibling c6-direct c8-root],
                   c7_row["unmet_dependencies"].map { |u| u["blocked_by"] }

      # C9 independently broken descendant: keeps own admission_error AND carries inherited c5-root
      c9_row = by_slug.fetch("c9-own-defect")
      assert_equal "admission_error", c9_row["action"]
      assert_equal "F9", c9_row.dig("admission_error", "offending_ref")
      assert_equal [ "c5-root" ], c9_row["dependency_repair_roots"].map { |r| r["slug"] }

      # StatusConsumer producer->consumer round trip preserves dependency_repair_roots without fallback
      consumer = Hive::Daemon::StatusConsumer.new(producer: ->(**) { payload })
      consumed = consumer.fetch
      assert consumed.ok
      consumed_by_slug = consumed.rows.to_h { |r| [ r.slug, r ] }
      assert_nil consumed_by_slug["c6-direct"].admission_error
      assert_equal "c5-root", consumed_by_slug["c6-direct"].dependency_repair_roots.first["slug"]
      assert_equal %w[c5-root c8-root],
                   consumed_by_slug["c7-fanin"].dependency_repair_roots.map { |r| r["slug"] }
      assert_equal "plan_dependency_invalid", consumed_by_slug["c5-root"].admission_error.reason_code

      # Backward compatibility: old rows without optional dependency_repair_roots consume cleanly
      old_payload = JSON.parse(JSON.generate(payload))
      old_payload["projects"].first["tasks"].each { |t| t.delete("dependency_repair_roots") }
      old_consumed = Hive::Daemon::StatusConsumer.new(producer: ->(**) { old_payload }).fetch
      assert old_consumed.ok
      assert_equal [], old_consumed.rows.find { |r| r.slug == "c6-direct" }.dependency_repair_roots

      # OperationalStatus classification & schema validation
      op_payload = Hive::OperationalStatus.new(
        status_payload: payload,
        project_context: { "app" => { "daemon_enabled" => false } }
      ).to_h
      validate_schema!("hive-operational-status", op_payload)
      op_by_slug = op_payload.fetch("tasks").to_h { |t| [ t.dig("identity", "slug"), t ] }

      assert_equal "needs_repair", op_by_slug["c5-root"]["state"]
      assert_equal "operator", op_by_slug["c5-root"]["blocker_owner"]

      assert_equal "waiting_on_provider_or_scheduler", op_by_slug["c6-direct"]["state"]
      assert_equal "scheduler", op_by_slug["c6-direct"]["blocker_owner"]
      assert_equal "blocked by app:c5-root: invalid depends_on F2, F3", op_by_slug["c6-direct"]["reason"]
      assert_equal [ "c5-root" ],
                   op_by_slug["c6-direct"].dig("dependency", "dependency_repair_roots").map { |r| r["slug"] }

      assert_equal "waiting_on_provider_or_scheduler", op_by_slug["c7-fanin"]["state"]
      assert_includes op_by_slug["c7-fanin"]["reason"],
                      "blocked by app:c5-root: invalid depends_on F2, F3; app:c8-root: invalid depends_on C4"
      assert_includes op_by_slug["c7-fanin"]["reason"], "waiting-sibling (4-execute, needs 9-done)"
      # c8-root is not duplicated as an ordinary unmet sibling once listed as a repair root
      refute_includes op_by_slug["c7-fanin"]["reason"], "c8-root (3-plan"

      assert_equal "needs_repair", op_by_slug["c9-own-defect"]["state"]
      assert_includes op_by_slug["c9-own-defect"]["reasons"].map { |r| r["code"] }, "plan_dependency_invalid"
      assert_includes op_by_slug["c9-own-defect"]["reasons"].map { |r| r["code"] }, "dependency_wait"

      # Daemon Policy & Dispatcher one-shot wait bucket verification
      c6_daemon = consumed_by_slug["c6-direct"]
      c5_daemon = consumed_by_slug["c5-root"]
      c6_decision = Hive::Daemon::Policy.decide(
        action: c6_daemon.action, stage: c6_daemon.stage, workflow: c6_daemon.workflow,
        command: c6_daemon.suggested_command, state_file_mtime: c6_daemon.state_file_mtime,
        last_dispatched_state_file_mtime: nil, now: Time.now.utc,
        blocked: c6_daemon.blocked, admission_error: !c6_daemon.admission_error.nil?
      )
      assert_equal :blocked_on_dependency, c6_decision
      c5_decision = Hive::Daemon::Policy.decide(
        action: c5_daemon.action, stage: c5_daemon.stage, workflow: c5_daemon.workflow,
        command: c5_daemon.suggested_command, state_file_mtime: c5_daemon.state_file_mtime,
        last_dispatched_state_file_mtime: nil, now: Time.now.utc,
        blocked: c5_daemon.blocked, admission_error: !c5_daemon.admission_error.nil?
      )
      assert_equal :admission_error, c5_decision

      dispatcher = Hive::Daemon::Dispatcher.allocate
      c6_blockers = dispatcher.send(:dependency_blockers, c6_daemon)
      assert_includes c6_blockers, "app:c5-root"

      # TUI Snapshot, TasksPane, and RedStatusDetail
      snapshot = Hive::Tui::Snapshot.from_payload(payload)
      tui_rows = snapshot.projects.first.rows.to_h { |r| [ r.slug, r ] }

      c5_label = Hive::Tui::Views::TasksPane.status_label(tui_rows["c5-root"])
      assert_includes c5_label, "ADMISSION plan_dependency_invalid"
      c6_label = Hive::Tui::Views::TasksPane.status_label(tui_rows["c6-direct"])
      refute_includes c6_label, "ADMISSION"
      assert_includes c6_label, "⏸ blocked by app:c5-root: invalid depends_on F2, F3"
      c7_label = Hive::Tui::Views::TasksPane.status_label(tui_rows["c7-fanin"])
      assert_includes c7_label, "app:c5-root: invalid depends_on F2, F3; app:c8-root: invalid depends_on C4"
      assert_includes c7_label, "waiting-sibling"

      detail_lines = Hive::Tui::Views::RedStatusDetail.repair_root_lines(tui_rows["c9-own-defect"], 120).join("\n")
      assert_includes detail_lines, "app:c5-root: invalid depends_on F2, F3"
      assert_includes detail_lines, "[index 0] F2"
      assert_includes detail_lines, "f2-payments-261030-aaaa"

      # Web StatusPayload preserves dependency_repair_roots
      web_payload = Hive::Web::StatusPayload.call(payload)
      web_c6 = web_payload.fetch("projects").first.fetch("tasks").find { |t| t["slug"] == "c6-direct" }
      assert_equal c6_row["dependency_repair_roots"], web_c6["dependency_repair_roots"]

      # Hive::Commands::Task JSON & text detail view
      task_out, = capture_io do
        doc = Hive::Commands::Task.new("c6-direct", project: "app").call
        validate_schema!("hive-task-workspace", doc)
        assert_equal "waiting", doc.dig("headline", "state")
        assert_includes doc.dig("headline", "explanation"), "app:c5-root: invalid depends_on F2, F3"
        assert_equal [ "c5-root" ],
                     doc.dig("diagnostic", "dependency_repair_roots").map { |r| r["slug"] }
      end
      assert_includes task_out, "Dependency repair roots:"
      assert_includes task_out, "[index 0] F2"
      assert_includes task_out, "f2-payments-261030-aaaa"

      # Hive::TaskWorkspace::DependencyComponent exposes dependency_repair_roots for web _dependencies partial
      admission_context = Hive::DependencySnapshot.admission_context(registry)
      dep_component = Hive::TaskWorkspace::DependencyComponent.new(
        context: admission_context, project: "app", slug: "c6-direct"
      ).call
      c6_node = dep_component.fetch("records").find { |n| n["root"] }
      assert_equal "wait", c6_node.dig("admission", "state")
      assert_equal [ "c5-root" ],
                   c6_node.dig("admission", "dependency_repair_roots").map { |r| r["slug"] }

      # Hive::Commands::Status text output renders root-directed waits cleanly
      status_text, = capture_io do
        Hive::Commands::Status.new(json: false, full: true).call
      end
      assert_includes status_text, "blocked by app:c5-root: invalid depends_on F2, F3"
      assert_includes status_text, "app:c5-root: invalid depends_on F2, F3; app:c8-root: invalid depends_on C4"

      # Hive::Daemon::Dispatcher classifies an inherited-only row (no ordinary unmet edges) as waiting_external
      inherited_only_row = Hive::Daemon::StatusConsumer::Row.new(
        project: "app", slug: "c6-inherited-only", stage: "3-plan",
        folder: tasks[:c6].folder, state_file: File.join(tasks[:c6].folder, "plan.md"),
        marker: "complete", action: "ready_to_develop",
        suggested_command: "hive develop c6-inherited-only --project app --from 3-plan",
        depends_on: "c5-root", blocked_by: nil, dependency_stage: nil,
        unmet_dependencies: [], dependency_repair_roots: c6_row["dependency_repair_roots"],
        blocked: true, admission_error: nil, state_file_mtime: Time.now.utc,
        claude_pid_alive: nil
      )
      dispatcher = Hive::Daemon::Dispatcher.allocate
      assert_equal [ "app:c5-root" ], dispatcher.send(:dependency_blockers, inherited_only_row)
      inherited_decision = Hive::Daemon::Policy.decide(
        action: inherited_only_row.action,
        stage: inherited_only_row.stage,
        command: inherited_only_row.suggested_command,
        state_file_mtime: inherited_only_row.state_file_mtime,
        last_dispatched_state_file_mtime: nil,
        blocked: inherited_only_row.blocked,
        admission_error: !inherited_only_row.admission_error.nil?,
        now: Time.now.utc
      )
      assert_equal :blocked_on_dependency, inherited_decision

      # Hive::Daemon::OperationalSnapshot carries dependency_repair_roots when non-empty
      assembler = Hive::Daemon::OperationalSnapshot::Assembler.allocate
      snap_c6 = assembler.send(:task_record, inherited_only_row)
      assert_equal [ "c5-root" ], snap_c6.fetch("dependency_repair_roots").map { |r| r["slug"] }

      # Fresh recovery: repairing C5 removes inherited repair evidence across surfaces while retaining gate waits
      File.write(
        File.join(tasks[:c5].folder, "plan.md"),
        "---\ndepends_on:\n  - f2-payments-261030-aaaa\n  - f3-ledger-261030-bbbb\n---\n# C5 Fixed\n<!-- COMPLETE -->\n"
      )
      Hive::TaskMeta.rewrite(
        tasks[:c5].folder,
        { depends_on: %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb] }
      )
      recovered_payload = Hive::Commands::Status.new(json: true).json_payload(registry)
      validate_schema!("hive-status", recovered_payload)
      rec_by_slug = recovered_payload.fetch("projects").first.fetch("tasks").to_h { |t| [ t["slug"], t ] }

      refute rec_by_slug["c5-root"]["blocked"]
      assert_nil rec_by_slug["c5-root"]["admission_error"]
      refute rec_by_slug["c6-direct"].key?("dependency_repair_roots")
      assert_equal true, rec_by_slug["c6-direct"]["blocked"]
      assert_equal "c5-root", rec_by_slug["c6-direct"]["blocked_by"]
      assert_equal [ "c8-root" ], rec_by_slug["c7-fanin"]["dependency_repair_roots"].map { |r| r["slug"] }

      rec_op = Hive::OperationalStatus.new(
        status_payload: recovered_payload,
        project_context: { "app" => { "daemon_enabled" => false } }
      ).to_h
      validate_schema!("hive-operational-status", rec_op)
      rec_c6_op = rec_op.fetch("tasks").find { |t| t.dig("identity", "slug") == "c6-direct" }
      refute_includes rec_c6_op["reason"], "invalid depends_on"
      assert_includes rec_c6_op["reason"], "c5-root (3-plan)"
    end
  end

  def test_stack_json_schema_accepts_optional_dependency_repair_roots
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-stack"))))
    base = {
      "schema" => "hive-stack", "schema_version" => 1, "ok" => true,
      "project" => "app", "slug" => "c6-direct", "id" => 6, "stage" => "2-brainstorm",
      "depends_on" => "c5-root", "previous_depends_on" => nil,
      "changed" => true, "committed" => true,
      "dependency" => {
        "state" => "wait",
        "unmet_dependencies" => [],
        "admission_error" => nil,
        "dependency_repair_roots" => [
          {
            "project" => "app", "slug" => "c5-root",
            "reason_code" => "plan_dependency_invalid",
            "offending_ref" => "F2, F3",
            "safe_correction" => "Repair app:c5-root.",
            "issues" => [
              {
                "index" => 0, "raw_value" => "F2", "display_value" => "F2",
                "code" => "task_code_shorthand", "message" => "invalid shorthand",
                "suggestion" => "f2-payments-261030-aaaa"
              }
            ]
          }
        ]
      },
      "notes" => []
    }
    assert_empty schemer.validate(base).to_a

    without_optional = JSON.parse(JSON.generate(base))
    without_optional["dependency"].delete("dependency_repair_roots")
    assert_empty schemer.validate(without_optional).to_a
  end
end
