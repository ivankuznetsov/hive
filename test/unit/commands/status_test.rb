require "test_helper"
require "hive/commands/status"
require "hive/task_action"

class CommandsStatusTest < Minitest::Test
  include HiveTestHelper

  def test_json_payload_ignores_archived_manual_stage_sibling
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      active = File.join(hive_state, "stages", "4-execute", "active-task")
      archived = File.join(hive_state, "stages", "archived-manual", "manual-task")
      FileUtils.mkdir_p(active)
      FileUtils.mkdir_p(archived)
      File.write(File.join(active, "task.md"), "# Active\n<!-- EXECUTE_WAITING -->\n")
      File.write(File.join(archived, "task.md"), "# Archived manually\n<!-- MANUAL_STEERING -->\n")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])

      slugs = payload.fetch("projects").first.fetch("tasks").map { |task| task.fetch("slug") }
      assert_includes slugs, "active-task"
      refute_includes slugs, "manual-task"
      assert_equal [], payload.fetch("projects").first.fetch("legacy_stage_dirs"),
                   "archived-manual is an intentional status-private sibling, not a legacy stage"
      assert_nil payload.fetch("projects").first.fetch("legacy_migrate_command")
    end
  end

  def test_json_payload_emits_live_task_lock_as_strict_boolean
    # Fix #144 regression guard: external consumers (TUI, daemon, bots)
    # rely on `live_task_lock` to render the runner badge without
    # re-parsing the .lock file. Must be a strict boolean — never null —
    # even when the underlying classifier returned nil (no .lock file).
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      live_folder = File.join(hive_state, "stages", "4-execute", "live-task-260525-aaaa")
      idle_folder = File.join(hive_state, "stages", "4-execute", "idle-task-260525-bbbb")
      FileUtils.mkdir_p(live_folder)
      FileUtils.mkdir_p(idle_folder)
      File.write(File.join(live_folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(live_folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid)
      ))
      File.write(File.join(idle_folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])
      tasks = payload.fetch("projects").first.fetch("tasks")
      live = tasks.find { |t| t.fetch("slug") == "live-task-260525-aaaa" }
      idle = tasks.find { |t| t.fetch("slug") == "idle-task-260525-bbbb" }

      assert_equal true, live.fetch("live_task_lock")
      assert_equal false, idle.fetch("live_task_lock"),
                   "rows without a .lock must serialise as false, never nil"
    end
  end

  def test_json_payload_emits_folder_mtime_and_keeps_old_archived_tasks
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "9-done", "old-archived-260604-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- COMPLETE -->\n")
      old = Time.now - (5 * 86_400)
      File.utime(old, old, folder)

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])
      tasks = payload.fetch("projects").first.fetch("tasks")
      archived = tasks.find { |task| task.fetch("slug") == "old-archived-260604-abcd" }

      refute_nil archived, "default JSON must keep old archived rows visible to bots and daemons"
      assert_equal old.utc.iso8601(6), archived.fetch("folder_mtime")
    end
  end

  def test_json_payload_default_path_matches_explicit_full_stage_inputs
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      write_status_task(hive_state, "4-execute", "active-task-260626-abcd",
                        state_file: "task.md", marker: "EXECUTE_COMPLETE")
      write_status_task(hive_state, "9-done", "archived-task-260626-abcd",
                        state_file: "task.md", marker: "COMPLETE")
      projects = [ status_project(project_root, hive_state) ]
      now = Time.utc(2026, 6, 26, 12, 0, 0)

      default_json = explicit_json = nil
      with_replaced_singleton_method(Time, :now, -> { now }) do
        default_json = JSON.generate(Hive::Commands::Status.new.json_payload(projects))
        explicit_json = JSON.generate(
          Hive::Commands::Status.new.json_payload(
            projects,
            stages: Hive::Workflows.all_stage_dirs,
            extra_dependency_tasks: {}
          )
        )
      end

      assert_equal default_json, explicit_json,
                   "no-kwargs status JSON must match the explicit full-snapshot path byte-for-byte"
    end
  end

  def test_json_payload_with_stage_filter_returns_only_requested_stages
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      active = write_status_task(hive_state, "4-execute", "active-task-260626-abcd",
                                 state_file: "task.md", marker: "EXECUTE_COMPLETE")
      archived = write_status_task(hive_state, "9-done", "archived-task-260626-abcd",
                                   state_file: "task.md", marker: "COMPLETE")
      Hive::TaskMeta.write(active, id: 1, slug: File.basename(active), display_name: nil)
      Hive::TaskMeta.write(archived, id: 2, slug: File.basename(archived), display_name: nil)
      active_stages = Hive::Workflows.all_stage_dirs - [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ]

      tasks = Hive::Commands::Status.new.json_payload(
        [ status_project(project_root, hive_state) ],
        stages: active_stages
      ).fetch("projects").first.fetch("tasks")

      assert_equal [ "active-task-260626-abcd" ], tasks.map { |task| task.fetch("slug") }
    end
  end

  def test_json_payload_emits_workflow_id_for_scanned_tasks
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "4-execute", "coding-task-260618-abcd", marker: "EXECUTE_COMPLETE", age_days: 0)

      payload = Hive::Commands::Status.new.json_payload([
        status_project(project_root, hive_state)
      ])
      task = payload.fetch("projects").first.fetch("tasks").find do |candidate|
        candidate.fetch("slug") == "coding-task-260618-abcd"
      end

      assert_equal "coding", task.fetch("workflow")
    end
  end

  def test_json_payload_surfaces_error_row_for_unloadable_task_and_stays_silent_on_non_slug
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "broken-wf-260620-abcd"
      folder = File.join(hive_state, "stages", "4-execute", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      # Unregistered workflow selector → Task.new raises InvalidTaskPath, which
      # previously vanished the task (and a typo'd project default emptied the
      # whole project to zero rows).
      Hive::TaskMeta.write(folder, id: 5, slug: slug, display_name: nil, workflow: "ghost-workflow")
      # A non-slug sibling dir must stay silent — no row, no warn.
      FileUtils.mkdir_p(File.join(hive_state, "stages", "4-execute", "NotASlug"))

      payload = nil
      _out, err = capture_io do
        payload = Hive::Commands::Status.new.json_payload([
          status_project(project_root, hive_state)
        ])
      end

      tasks = payload.fetch("projects").first.fetch("tasks")
      row = tasks.find { |candidate| candidate.fetch("slug") == slug }

      refute_nil row, "an unloadable task must surface as an Error row, not vanish from status"
      assert_equal "error", row.fetch("action")
      assert_equal "error", row.fetch("marker")
      assert_equal "invalid_task", row.fetch("attrs").fetch("reason")
      assert_includes row.fetch("attrs").fetch("message"), "ghost-workflow"
      refute row.key?("workflow"), "an unresolved workflow is omitted, not emitted as null"
      assert_match(/failed to load/, err)

      refute(tasks.any? { |candidate| candidate.fetch("slug") == "NotASlug" },
             "a non-slug dir must not surface as a row")
      refute_match(/NotASlug/, err, "a non-slug dir must not warn")
    end
  end

  def test_json_payload_scans_registered_generic_stage_dirs
    descriptor = dispatch_workflow

    with_registered_workflow(descriptor) do
      with_tmp_dir do |project_root|
        hive_state = File.join(project_root, ".hive-state")
        slug = "generic-task-260620-abcd"
        folder = File.join(hive_state, "stages", "2-gather", slug)
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: 77, slug: slug, display_name: "Generic Task", workflow: descriptor.id.to_s)
        File.write(File.join(folder, "gather.md"), "<!-- WAITING -->\n")

        payload = Hive::Commands::Status.new.json_payload([
          status_project(project_root, hive_state)
        ])
        project = payload.fetch("projects").first
        task = project.fetch("tasks").find { |candidate| candidate.fetch("slug") == slug }

        refute_nil task
        assert_equal "2-gather", task.fetch("stage")
        assert_equal "dispatch", task.fetch("workflow")
        assert_equal [], project.fetch("legacy_stage_dirs")
      end
    end
  end

  def test_json_payload_populates_pr_url_from_pr_md_frontmatter_in_review_stage
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "6-review", "review-task-260615-abcd")
      pr_url = "https://github.com/example/repo/pull/561"
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- REVIEW_WAITING escalations=1 pass=1 -->\n")
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        pr_url: #{pr_url}
        ---
        # Pull request
      MD

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])
      task = payload.fetch("projects").first.fetch("tasks").find do |candidate|
        candidate.fetch("slug") == "review-task-260615-abcd"
      end

      assert_equal "6-review", task.fetch("stage")
      assert_equal pr_url, task.fetch("pr_url")
      assert_nil task.fetch("attrs")["pr_url"],
                 "pr_url is a sibling JSON field, not marker attrs from task.md"
    end
  end

  def test_json_payload_emits_nil_pr_url_before_open_pr_and_for_blank_or_malformed_pr_md
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      early = File.join(hive_state, "stages", "2-brainstorm", "early-task-260615-abcd")
      blank = File.join(hive_state, "stages", "5-open-pr", "blank-pr-260615-abcd")
      malformed = File.join(hive_state, "stages", "6-review", "malformed-pr-260615-abcd")
      FileUtils.mkdir_p(early)
      FileUtils.mkdir_p(blank)
      FileUtils.mkdir_p(malformed)
      File.write(File.join(early, "brainstorm.md"), "<!-- WAITING -->\n")
      File.write(File.join(blank, "pr.md"), "<!-- COMPLETE -->\n")
      File.write(File.join(malformed, "task.md"), "<!-- REVIEW_WAITING escalations=1 pass=1 -->\n")
      File.write(File.join(malformed, "pr.md"), "---\npr_url: [unclosed\n---\n<!-- COMPLETE -->\n")

      payload = nil
      _out, _err = capture_io do
        payload = Hive::Commands::Status.new.json_payload([
          { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
        ])
      end
      tasks = payload.fetch("projects").first.fetch("tasks")

      assert_nil tasks.find { |task| task.fetch("slug") == "early-task-260615-abcd" }.fetch("pr_url")
      assert_nil tasks.find { |task| task.fetch("slug") == "blank-pr-260615-abcd" }.fetch("pr_url")
      assert_nil tasks.find { |task| task.fetch("slug") == "malformed-pr-260615-abcd" }.fetch("pr_url")
    end
  end

  # #270: a held brainstorm exposes its unanswered-question count so a
  # consumer can tell "daemon is holding this" from "broken". Every other
  # row reports 0.
  def test_json_payload_emits_unanswered_questions_for_held_brainstorm
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      bs = File.join(hive_state, "stages", "2-brainstorm", "bs-task-260525-cccc")
      ex = File.join(hive_state, "stages", "4-execute", "ex-task-260525-dddd")
      FileUtils.mkdir_p(bs)
      FileUtils.mkdir_p(ex)
      # Q1 unanswered, Q2 answered → count 1; WAITING marker → needs_input.
      File.write(File.join(bs, "brainstorm.md"),
                 "## Round 1\n### Q1.\nWhat?\n### A1.\n\n### Q2.\nWhy?\n### A2.\nyes\n<!-- WAITING -->\n")
      File.write(File.join(ex, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")

      tasks = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ]).fetch("projects").first.fetch("tasks")
      brainstorm = tasks.find { |t| t.fetch("slug") == "bs-task-260525-cccc" }
      execute = tasks.find { |t| t.fetch("slug") == "ex-task-260525-dddd" }

      assert_equal "needs_input", brainstorm.fetch("action"),
                   "precondition: the brainstorm row is a needs_input hold"
      assert_equal 1, brainstorm.fetch("unanswered_questions")
      assert_equal 0, execute.fetch("unanswered_questions"),
                   "non-brainstorm rows always report 0"
    end
  end

  # A non-coding workflow that reuses the `2-brainstorm` dir has no coding
  # Q&A answer flow, so unanswered_questions must report 0 even if a stray
  # `### Q{n}.` file is present — the gate keys on the coding workflow, not
  # just the dir name.
  def test_json_payload_unanswered_questions_zero_for_generic_brainstorm_dir
    descriptor = collision_workflow

    with_registered_workflow(descriptor) do
      with_tmp_dir do |project_root|
        hive_state = File.join(project_root, ".hive-state")
        slug = "generic-bs-260620-eeee"
        folder = File.join(hive_state, "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: 88, slug: slug, display_name: "Generic BS", workflow: descriptor.id.to_s)
        File.write(File.join(folder, "brainstorm.md"),
                   "## Round 1\n### Q1.\nWhat?\n### A1.\n\n<!-- WAITING -->\n")

        task = Hive::Commands::Status.new.json_payload([
          status_project(project_root, hive_state)
        ]).fetch("projects").first.fetch("tasks").find { |t| t.fetch("slug") == slug }

        assert_equal "collision", task.fetch("workflow"), "precondition: generic workflow row"
        assert_equal "needs_input", task.fetch("action"), "precondition: a WAITING generic stage is needs_input"
        assert_equal 0, task.fetch("unanswered_questions"),
                     "a generic 2-brainstorm row must not be counted for coding Q&A"
      end
    end
  end

  def test_json_payload_emits_resolved_dependency_state
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      base = write_status_task(hive_state, "7-artifacts", "base-task-260618-aaaa",
                               state_file: "artifact.md", marker: "COMPLETE")
      dependent = write_status_task(hive_state, "4-execute", "dependent-task-260618-bbbb",
                                    state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(base, id: 1, slug: File.basename(base), display_name: nil)
      Hive::TaskMeta.write(dependent, id: 2, slug: File.basename(dependent),
                                      display_name: nil, depends_on: File.basename(base))

      tasks = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ]).fetch("projects").first.fetch("tasks")
      row = tasks.find { |task| task.fetch("slug") == File.basename(dependent) }

      assert_equal File.basename(base), row.fetch("depends_on")
      assert_equal File.basename(base), row.fetch("blocked_by")
      assert_equal "7-artifacts", row.fetch("dependency_stage")
      assert_equal true, row.fetch("blocked")
    end
  end

  def test_coding_status_rows_and_legacy_dirs_are_characterized
    # U6 characterization: descriptor routing must not change the coding row
    # actions or legacy-stage warning shape.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      write_status_task(hive_state, "2-brainstorm", "brainstorm-task-260620-aaaa",
                        state_file: "brainstorm.md", marker: "COMPLETE")
      write_status_task(hive_state, "3-plan", "plan-task-260620-bbbb",
                        state_file: "plan.md", marker: "WAITING")
      write_status_task(hive_state, "4-execute", "execute-task-260620-cccc",
                        state_file: "task.md", marker: "EXECUTE_COMPLETE")
      legacy = File.join(hive_state, "stages", "5-review", "legacy-task-260620-dddd")
      FileUtils.mkdir_p(legacy)
      File.write(File.join(legacy, "task.md"), "<!-- COMPLETE -->\n")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])
      project = payload.fetch("projects").first
      actions_by_slug = project.fetch("tasks").to_h { |task| [ task.fetch("slug"), task.fetch("action") ] }

      assert_equal({
        "brainstorm-task-260620-aaaa" => "ready_to_plan",
        "plan-task-260620-bbbb" => "needs_input",
        "execute-task-260620-cccc" => "ready_to_open_pr"
      }, actions_by_slug)
      assert_equal [ { "stage_dir" => "5-review", "task_count" => 1 } ],
                   project.fetch("legacy_stage_dirs")
      assert_equal "hive migrate", project.fetch("legacy_migrate_command")
    end
  end

  def test_json_payload_unblocks_dependency_at_gate_stage
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      base = write_status_task(hive_state, "8-finalize", "base-task-260618-aaaa",
                               state_file: "pr.md", marker: "COMPLETE")
      dependent = write_status_task(hive_state, "4-execute", "dependent-task-260618-bbbb",
                                    state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(base, id: 1, slug: File.basename(base), display_name: nil)
      Hive::TaskMeta.write(dependent, id: 2, slug: File.basename(dependent),
                                      display_name: nil, depends_on: File.basename(base))

      tasks = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ]).fetch("projects").first.fetch("tasks")
      row = tasks.find { |task| task.fetch("slug") == File.basename(dependent) }

      assert_equal File.basename(base), row.fetch("blocked_by")
      assert_equal "8-finalize", row.fetch("dependency_stage")
      assert_equal false, row.fetch("blocked")
    end
  end

  def test_active_only_payload_resolves_dependency_from_extra_dependency_tasks
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      dependent = write_status_task(hive_state, "4-execute", "dependent-task-260626-bbbb",
                                    state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(dependent, id: 2, slug: File.basename(dependent),
                                      display_name: nil, depends_on: "archived-task-260626-aaaa")
      active_stages = Hive::Workflows.all_stage_dirs - [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ]
      project = status_project(project_root, hive_state)

      unresolved = Hive::Commands::Status.new.json_payload([ project ], stages: active_stages)
                      .fetch("projects").first.fetch("tasks").first
      blocked = Hive::Commands::Status.new.json_payload(
        [ project ],
        stages: active_stages,
        extra_dependency_tasks: {
          project.fetch("path") => [
            { slug: "archived-task-260626-aaaa", id: 1, stage: "7-artifacts", stage_index: 7 }
          ]
        }
      ).fetch("projects").first.fetch("tasks").first
      unblocked = Hive::Commands::Status.new.json_payload(
        [ project ],
        stages: active_stages,
        extra_dependency_tasks: {
          project.fetch("path") => [
            { "slug" => "archived-task-260626-aaaa", "id" => 1, "stage" => "9-done" }
          ]
        }
      ).fetch("projects").first.fetch("tasks").first

      assert_equal true, unresolved.fetch("blocked")
      assert_nil unresolved.fetch("blocked_by"),
                 "without archived identities, active-only dependency resolution is unresolved"
      assert_equal true, blocked.fetch("blocked")
      assert_equal "archived-task-260626-aaaa", blocked.fetch("blocked_by")
      assert_equal "7-artifacts", blocked.fetch("dependency_stage")
      assert_equal false, unblocked.fetch("blocked")
      assert_equal "archived-task-260626-aaaa", unblocked.fetch("blocked_by")
      assert_equal "9-done", unblocked.fetch("dependency_stage")
    end
  end

  def test_json_payload_and_text_render_unresolved_dependency
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      dependent = write_status_task(hive_state, "4-execute", "dependent-task-260618-bbbb",
                                    state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(dependent, id: 2, slug: File.basename(dependent),
                                      display_name: nil, depends_on: "missing-task")

      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      tasks = Hive::Commands::Status.new.json_payload([ project ]).fetch("projects").first.fetch("tasks")
      row = tasks.find { |task| task.fetch("slug") == File.basename(dependent) }

      assert_equal "missing-task", row.fetch("depends_on")
      assert_nil row.fetch("blocked_by")
      assert_nil row.fetch("dependency_stage")
      assert_equal true, row.fetch("blocked")

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, project, project_count: 1)
      end
      assert_includes out, "⏸ blocked by missing-task (unresolved)"
    end
  end

  def test_text_status_renders_quota_held_error_label
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      retry_after = "2026-06-24T23:20:00Z"
      write_status_task(hive_state, "4-execute", "quota-task-260624-abcd",
                        state_file: "task.md",
                        marker: "ERROR reason=limits_reached provider=codex retry_after=#{retry_after}")

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      # Assert against the shared contract this renderer delegates to rather
      # than re-pinning the literal (the one canonical literal pin lives in
      # agent_limit_test.rb) — this directly tests the no-divergence invariant.
      assert_includes out, Hive::AgentLimit.held_label("provider" => "codex", "retry_after" => retry_after)
      refute_includes out, "reason=limits_reached",
                      "held quota rows must render the shared label instead of a raw attr dump"
    end
  end

  def test_json_payload_emits_quota_held_field_without_overloading_dependency_block
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      retry_after = "2026-06-24T23:20:00Z"
      write_status_task(hive_state, "4-execute", "quota-task-260624-abcd",
                        state_file: "task.md",
                        marker: "ERROR reason=limits_reached provider=codex retry_after=#{retry_after}")

      task = Hive::Commands::Status.new.json_payload([
        status_project(project_root, hive_state)
      ]).fetch("projects").first.fetch("tasks").find { |row| row.fetch("slug") == "quota-task-260624-abcd" }

      assert_equal({
        "reason" => "quota",
        "provider" => "codex",
        "retry_after" => retry_after
      }, task.fetch("held"))
      assert_equal false, task.fetch("blocked")
      assert_nil task.fetch("blocked_by")
    end
  end

  # The resolved branch of the text-mode indicator was only exercised via
  # the TUI's separate renderer, so swapping the two branches in
  # Commands::Status would have passed every test. Pin a below-gate
  # resolvable prereq through render_project.
  def test_render_project_renders_resolved_dependency_indicator
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      base = write_status_task(hive_state, "7-artifacts", "base-task-260618-aaaa",
                               state_file: "artifact.md", marker: "COMPLETE")
      dependent = write_status_task(hive_state, "4-execute", "dependent-task-260618-bbbb",
                                    state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(base, id: 1, slug: File.basename(base), display_name: nil)
      Hive::TaskMeta.write(dependent, id: 2, slug: File.basename(dependent),
                                      display_name: nil, depends_on: File.basename(base))

      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, project, project_count: 1)
      end

      assert_includes out, "⏸ blocked by #{File.basename(base)} (7-artifacts)"
      refute_includes out, "(unresolved)", "a resolved prereq must NOT render the unresolved variant"
    end
  end

  # CLAUDE.md test-rule 10: a dispatchable dependent (blocked:false, prereq
  # past the gate) still carries depends_on/blocked_by, but must NOT render
  # the "⏸ blocked by" indicator. dependency_indicator keys off `blocked`,
  # not field presence — only an absence check catches a regression that
  # keyed the badge off depends_on/blocked_by presence.
  def test_render_project_omits_indicator_for_unblocked_dependent
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      base = write_status_task(hive_state, "8-finalize", "base-task-260618-aaaa",
                               state_file: "pr.md", marker: "COMPLETE")
      dependent = write_status_task(hive_state, "4-execute", "dependent-task-260618-bbbb",
                                    state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(base, id: 1, slug: File.basename(base), display_name: nil)
      Hive::TaskMeta.write(dependent, id: 2, slug: File.basename(dependent),
                                      display_name: nil, depends_on: File.basename(base))

      project = { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, project, project_count: 1)
      end

      refute_includes out, "⏸ blocked by",
                      "a dispatchable (unblocked) dependent must not render the held indicator"
    end
  end

  # The per-row fail-open rescue in apply_dependency_result is a finer-grained
  # net than the project-level degrade: one row whose resolve raises must
  # serialize blocked:false with a breadcrumb while sibling rows keep their
  # resolved dependency state. Without this test, removing the per-row rescue
  # (collapsing back to whole-project degradation) passes every other test.
  def test_one_raising_dependency_row_fails_open_without_blanking_siblings
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      base = write_status_task(hive_state, "7-artifacts", "base-task-260618-aaaa",
                               state_file: "artifact.md", marker: "COMPLETE")
      good = write_status_task(hive_state, "4-execute", "good-dependent-260618-bbbb",
                               state_file: "task.md", marker: "EXECUTE_COMPLETE")
      bad = write_status_task(hive_state, "4-execute", "bad-dependent-260618-cccc",
                              state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(base, id: 1, slug: File.basename(base), display_name: nil)
      Hive::TaskMeta.write(good, id: 2, slug: File.basename(good),
                                 display_name: nil, depends_on: File.basename(base))
      Hive::TaskMeta.write(bad, id: 3, slug: File.basename(bad),
                                display_name: nil, depends_on: File.basename(base))

      original = Hive::Dependencies.method(:resolve)
      raising = lambda do |depends_on:, tasks:, threshold_stage:, task: nil|
        raise "boom" if task && task[:slug] == File.basename(bad)

        original.call(depends_on: depends_on, tasks: tasks,
                      threshold_stage: threshold_stage, task: task)
      end

      payload = nil
      _out, err = capture_io do
        with_replaced_singleton_method(Hive::Dependencies, :resolve, raising) do
          payload = Hive::Commands::Status.new.json_payload([
            { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
          ])
        end
      end

      tasks = payload.fetch("projects").first.fetch("tasks")
      bad_row = tasks.find { |t| t.fetch("slug") == File.basename(bad) }
      good_row = tasks.find { |t| t.fetch("slug") == File.basename(good) }

      assert_equal false, bad_row.fetch("blocked"),
                   "a row whose resolve raises must fail open to blocked:false"
      assert_nil bad_row.fetch("blocked_by")
      assert_equal true, good_row.fetch("blocked"),
                   "a sibling row must keep its resolved dependency state, not be blanked by the raising row"
      assert_equal File.basename(base), good_row.fetch("blocked_by")
      assert_match(/dependency resolve failed for/, err,
                   "the per-row fail-open must leave a stderr breadcrumb")
    end
  end

  # End-to-end config→annotate_dependencies threshold wiring: a project that
  # raises the gate to 9-done blocks a prereq sitting at 8-finalize (which
  # would unblock under the default gate).
  def test_json_payload_honors_dependency_gate_stage_override
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      File.write(File.join(hive_state, "config.yml"), "dependency_gate_stage: 9-done\n")
      base = write_status_task(hive_state, "8-finalize", "base-task-260618-aaaa",
                               state_file: "pr.md", marker: "COMPLETE")
      dependent = write_status_task(hive_state, "4-execute", "dependent-task-260618-bbbb",
                                    state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(base, id: 1, slug: File.basename(base), display_name: nil)
      Hive::TaskMeta.write(dependent, id: 2, slug: File.basename(dependent),
                                      display_name: nil, depends_on: File.basename(base))

      tasks = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ]).fetch("projects").first.fetch("tasks")
      row = tasks.find { |task| task.fetch("slug") == File.basename(dependent) }

      assert_equal "8-finalize", row.fetch("dependency_stage")
      assert_equal true, row.fetch("blocked"),
                   "raising the gate to 9-done must keep an 8-finalize prereq blocking"
    end
  end

  # The `same_task?` self-reference branch runs in production via `task: row`
  # but was asserted only at the resolver level. A task depending on its own
  # slug must surface as blocked with no blocked_by through the JSON path.
  def test_json_payload_self_reference_dependency_is_blocked_unresolved
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      task = write_status_task(hive_state, "4-execute", "loop-task-260618-cccc",
                               state_file: "task.md", marker: "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(task, id: 1, slug: File.basename(task),
                                 display_name: nil, depends_on: File.basename(task))

      tasks = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ]).fetch("projects").first.fetch("tasks")
      row = tasks.find { |t| t.fetch("slug") == File.basename(task) }

      assert_equal true, row.fetch("blocked")
      assert_nil row.fetch("blocked_by")
      assert_nil row.fetch("dependency_stage")
    end
  end

  # Regression guard for the High finding: one project with an invalid
  # dependency_gate_stage (which Config.load rejects with ConfigError) must
  # NOT abort the whole `hive status --json` — that would feed the daemon
  # ok:false and freeze auto-advance fleet-wide. The dependency threshold
  # degrades to the global default (with a stderr breadcrumb) so the bad
  # project still reports its tasks and the healthy project is untouched.
  def test_json_payload_isolates_a_project_with_invalid_config
    with_tmp_dir do |bad_root|
      with_tmp_dir do |good_root|
        bad_state = File.join(bad_root, ".hive-state")
        good_state = File.join(good_root, ".hive-state")
        FileUtils.mkdir_p(bad_state)
        # 5-open-pr is below the allowed gate stages, so Config.load raises.
        File.write(File.join(bad_state, "config.yml"), "dependency_gate_stage: 5-open-pr\n")
        write_status_task(bad_state, "4-execute", "bad-proj-task-260618-aaaa",
                          state_file: "task.md", marker: "EXECUTE_COMPLETE")
        write_status_task(good_state, "4-execute", "good-proj-task-260618-bbbb",
                          state_file: "task.md", marker: "EXECUTE_COMPLETE")

        payload = nil
        _out, err = capture_io do
          payload = Hive::Commands::Status.new.json_payload([
            { "name" => "bad", "path" => bad_root, "hive_state_path" => bad_state },
            { "name" => "good", "path" => good_root, "hive_state_path" => good_state }
          ])
        end

        assert_equal true, payload.fetch("ok"),
                     "one bad project must not flip the whole status envelope to not-ok"
        bad = payload.fetch("projects").find { |p| p["name"] == "bad" }
        good = payload.fetch("projects").find { |p| p["name"] == "good" }
        bad_slugs = bad.fetch("tasks").map { |t| t["slug"] }
        good_slugs = good.fetch("tasks").map { |t| t["slug"] }
        assert_includes bad_slugs, "bad-proj-task-260618-aaaa",
                        "the bad-config project still reports tasks (gate falls back to default)"
        assert_includes good_slugs, "good-proj-task-260618-bbbb",
                        "a healthy project must still report its tasks"
        assert_match(/unusable dependency_gate_stage/, err,
                     "the degraded gate must leave a stderr breadcrumb")
      end
    end
  end

  # Belt-and-suspenders for the same freeze: any unexpected per-project
  # raise inside project_payload must degrade that one project to an empty
  # task list rather than abort the whole envelope.
  def test_json_payload_degrades_a_project_that_raises_unexpectedly
    raising = Class.new(Hive::Commands::Status) do
      def project_payload(project, **)
        raise "boom in #{project['name']}" if project["name"] == "explodes"

        super
      end
    end

    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      write_status_task(hive_state, "4-execute", "healthy-task-260618-eeee",
                        state_file: "task.md", marker: "EXECUTE_COMPLETE")

      payload = nil
      _out, err = capture_io do
        payload = raising.new.json_payload([
          { "name" => "explodes", "path" => project_root, "hive_state_path" => hive_state },
          { "name" => "healthy", "path" => project_root, "hive_state_path" => hive_state }
        ])
      end

      assert_equal true, payload.fetch("ok")
      exploded = payload.fetch("projects").find { |p| p["name"] == "explodes" }
      healthy = payload.fetch("projects").find { |p| p["name"] == "healthy" }
      assert_equal [], exploded.fetch("tasks"), "the exploding project degrades to no tasks"
      refute_empty healthy.fetch("tasks"), "the healthy project is unaffected"
      assert_match(/payload failed/, err)
    end
  end

  # Text-mode parity with the JSON per-project isolation: one project whose
  # render raises must degrade to a one-line breadcrumb (stdout + stderr) and
  # keep rendering the rest, never aborting `hive status` for the whole fleet.
  def test_text_status_isolates_a_project_that_fails_to_render
    raising = Class.new(Hive::Commands::Status) do
      def render_project(project, **)
        raise "boom in #{project['name']}" if project["name"] == "explodes"

        super
      end
    end

    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      write_status_task(hive_state, "4-execute", "healthy-text-260618-ffff",
                        state_file: "task.md", marker: "EXECUTE_COMPLETE")
      projects = [
        { "name" => "explodes", "path" => project_root, "hive_state_path" => hive_state },
        { "name" => "healthy", "path" => project_root, "hive_state_path" => hive_state }
      ]

      out = err = nil
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
        out, err = capture_io { raising.new.call }
      end

      assert_match(/explodes: failed to load \(boom in explodes\)/, out,
                   "the failing project degrades to a one-line stdout breadcrumb")
      assert_match(/failed to render/, err,
                   "the failure must leave a stderr breadcrumb")
      assert_match(/healthy-text-260618-ffff/, out,
                   "a healthy project must still render after a sibling fails")
    end
  end

  # #270: unanswered_question_count must never break `hive status` — a
  # parse error on a mid-write/malformed brainstorm.md degrades to 0.
  def test_unanswered_question_count_degrades_to_zero_on_parse_error
    with_tmp_dir do |dir|
      path = File.join(dir, "brainstorm.md")
      File.write(path, "## Round 1\n### Q1.\nWhat?\n### A1.\n\n")
      row = { action_key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
              stage: "2-brainstorm", state_file: path }
      with_replaced_singleton_method(Hive::BrainstormParser, :parse, ->(*) { raise "boom" }) do
        assert_equal 0, Hive::Commands::Status.new.send(:unanswered_question_count, row)
      end
    end
  end

  def test_call_rejects_empty_diagnose_and_write_without_diagnose
    error = assert_raises(Hive::Error) { Hive::Commands::Status.new(diagnose: "  ").call }
    assert_match(/--diagnose requires a non-empty task slug/, error.message)

    error = assert_raises(Hive::Error) { Hive::Commands::Status.new(write: true).call }
    assert_match(/--write requires --diagnose/, error.message)
  end

  def test_project_payload_and_text_render_report_missing_paths
    cmd = Hive::Commands::Status.new

    missing = cmd.project_payload(
      { "name" => "missing", "path" => "/tmp/no-such-hive-project", "hive_state_path" => "/tmp/nope/.hive-state" },
      project_count: 1
    )
    assert_equal "missing_project_path", missing.fetch("error")
    assert_equal [], missing.fetch("tasks")

    with_tmp_dir do |project_root|
      uninitialised = cmd.project_payload(
        { "name" => "plain", "path" => project_root, "hive_state_path" => File.join(project_root, ".hive-state") },
        project_count: 1
      )
      assert_equal "not_initialised", uninitialised.fetch("error")

      out, = capture_io do
        cmd.send(:render_project, { "name" => "plain", "path" => project_root,
                                    "hive_state_path" => File.join(project_root, ".hive-state") }, project_count: 1)
      end
      assert_includes out, "not initialised"
    end

    out, = capture_io do
      cmd.send(:render_project, { "name" => "missing", "path" => "/tmp/no-such-hive-project",
                                  "hive_state_path" => "/tmp/nope/.hive-state" }, project_count: 1)
    end
    assert_includes out, "missing project path"
  end

  def test_collect_rows_skips_invalid_entries_and_handles_live_agent_lock
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      execute_stage = File.join(hive_state, "stages", "4-execute")
      plan_stage = File.join(hive_state, "stages", "3-plan")
      FileUtils.mkdir_p(execute_stage)
      FileUtils.mkdir_p(plan_stage)
      File.write(File.join(execute_stage, "not-a-task.txt"), "skip me")
      FileUtils.mkdir_p(File.join(execute_stage, "BAD-SLUG"))

      live_folder = File.join(execute_stage, "live-agent-260522-abcd")
      FileUtils.mkdir_p(live_folder)
      File.write(File.join(live_folder, "task.md"), "<!-- AGENT_WORKING pid=1 -->\n")
      File.write(File.join(live_folder, ".lock"), YAML.dump("claude_pid" => Process.pid))
      File.write(File.join(live_folder, "worktree.yml"), "path: [")

      missing_state_folder = File.join(plan_stage, "missing-state-260522-abcd")
      FileUtils.mkdir_p(missing_state_folder)

      rows = Hive::Commands::Status.new.send(:collect_rows, hive_state)
      slugs = rows.map { |row| row.fetch(:slug) }

      assert_includes slugs, "live-agent-260522-abcd"
      assert_includes slugs, "missing-state-260522-abcd"
      refute_includes slugs, "BAD-SLUG"
      live = rows.find { |row| row[:slug] == "live-agent-260522-abcd" }
      assert_nil live.fetch(:worktree_path)
      assert_equal Process.pid.to_s, live.fetch(:claude_pid).to_s
      assert_equal true, live.fetch(:claude_pid_alive)
      assert_match(/agent_working pid=#{Process.pid}/, live.fetch(:state_label))

      liveness = Hive::Commands::Status.new.send(:liveness_kwargs_for, Hive::Task.new(live_folder))
      assert_equal true, liveness.fetch(:pid_alive)
    end
  end

  def test_collect_rows_skips_old_stage_entry_that_vanishes_mid_read
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "archive-race-260611-abcd"
      old_folder = create_finalize_ready_task(hive_state, slug)
      new_folder = File.join(hive_state, "stages", "9-done", slug)
      FileUtils.mkdir_p(File.dirname(new_folder))

      cmd = StatusRaceCommand.new(
        old_folder: old_folder,
        new_folder: new_folder,
        vanish_during_read_stage: "8-finalize"
      )
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      status_project(project_root, hive_state),
                      1,
                      with_diagnostic: false)
      race_rows = rows.select { |row| row.fetch(:slug) == slug }

      assert_equal 1, race_rows.size
      assert_equal "9-done", race_rows.first.fetch(:stage)
      refute_equal Hive::Schemas::TaskActionKind::ERROR, race_rows.first.fetch(:action_key)
      # Enforce — not just document — that the mid-read vanish actually fired.
      # The double's rename is timed by a `to_path` coercion count; if a
      # collect_rows refactor shifts that count the double silently stops
      # renaming and this test would pass vacuously. Assert it fired.
      assert cmd.vanish_double.renamed?,
             "vanish double never renamed: its to_path coercion-count trigger " \
             "has drifted, so this test is no longer exercising the race"
    end
  end

  def test_collect_rows_skips_non_finalize_stage_entry_that_vanishes_mid_read
    # The rescue keys on ENOENT + folder existence, NOT on the stage, so the
    # vanish/resurface dance must hold for any forward move — not just the
    # 8-finalize -> 9-done terminal case the other vanish test covers. Here a
    # task slips from 4-execute to 6-review mid-scan; it must resurface exactly
    # once under 6-review with a non-error action.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "execute-race-260611-abcd"
      old_folder = create_status_task(hive_state, "4-execute", slug,
                                      marker: "REVIEW_COMPLETE", age_days: 0)
      new_folder = File.join(hive_state, "stages", "6-review", slug)
      FileUtils.mkdir_p(File.dirname(new_folder))

      cmd = StatusRaceCommand.new(
        old_folder: old_folder,
        new_folder: new_folder,
        vanish_during_read_stage: "4-execute"
      )
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      status_project(project_root, hive_state),
                      1,
                      with_diagnostic: false)
      race_rows = rows.select { |row| row.fetch(:slug) == slug }

      assert_equal 1, race_rows.size
      assert_equal "6-review", race_rows.first.fetch(:stage)
      refute_equal Hive::Schemas::TaskActionKind::ERROR, race_rows.first.fetch(:action_key)
      assert cmd.vanish_double.renamed?,
             "vanish double never renamed: the 4-execute mid-read rename did not fire"
    end
  end

  def test_vanish_after_directory_check_path_renames_on_second_to_path_call
    # Pins the test double's timing contract independently of collect_rows'
    # internal call order: the rename must fire on to_path call 2 (the basename
    # slug-extraction coercion), never on call 1 (the directory? guard). The
    # vanish-during-read tests assert renamed? AFTER running collect_rows, so a
    # refactor that swapped File.basename(entry) for a non-File.* string op
    # (e.g. entry.split("/").last) while keeping a later File.*(entry) call
    # could leave them passing for the wrong reason; this decouples the timing
    # contract from collect_rows entirely.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "double-timing-260611-abcd"
      old_folder = create_finalize_ready_task(hive_state, slug)
      new_folder = File.join(hive_state, "stages", "9-done", slug)
      FileUtils.mkdir_p(File.dirname(new_folder))

      path = VanishAfterDirectoryCheckPath.new(old_folder, new_folder)

      assert_equal old_folder, path.to_path
      refute path.renamed?, "call 1 (the directory? guard) must not fire the rename"
      assert File.directory?(old_folder), "folder must still exist after to_path call 1"

      assert_equal old_folder, path.to_path
      assert path.renamed?, "to_path call 2 must fire the rename"
      refute File.directory?(old_folder), "old folder must be gone after the rename"
      assert File.directory?(new_folder), "folder must have moved to its new stage"
    end
  end

  def test_collect_rows_drops_old_stage_duplicate_when_rename_lands_before_new_stage_scan
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "archive-race-260611-bcde"
      old_folder = create_finalize_ready_task(hive_state, slug)
      new_folder = File.join(hive_state, "stages", "9-done", slug)
      FileUtils.mkdir_p(File.dirname(new_folder))

      cmd = StatusRaceCommand.new(
        old_folder: old_folder,
        new_folder: new_folder,
        rename_before_stage: "9-done"
      )
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      status_project(project_root, hive_state),
                      1,
                      with_diagnostic: false)
      race_rows = rows.select { |row| row.fetch(:slug) == slug }

      assert_equal 1, race_rows.size
      assert_equal "9-done", race_rows.first.fetch(:stage)
      refute_equal Hive::Schemas::TaskActionKind::ERROR, race_rows.first.fetch(:action_key)
    end
  end

  def test_collect_rows_reraises_enoent_when_folder_survives
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "corrupt-race-260611-abcd"
      folder = create_finalize_ready_task(hive_state, slug)

      # Force an ENOENT from the in-folder mtime read while the folder itself
      # survives on disk — the "corrupted-but-present" case (a state read
      # failing inside a folder that did NOT move stages). collect_rows'
      # `rescue Errno::ENOENT; raise if File.directory?(entry)` guard must
      # RE-RAISE this rather than swallow it; a refactor that turned the
      # `raise if` into an unconditional `next` would silently start hiding
      # genuine filesystem corruption, and only this test would catch it.
      original = File.singleton_class.instance_method(:mtime)
      File.define_singleton_method(:mtime) do |path|
        raise Errno::ENOENT, path.to_s if File.basename(path.to_s) == slug

        original.bind(File).call(path)
      end
      begin
        error = assert_raises(Errno::ENOENT) do
          Hive::Commands::Status.new.send(:collect_rows, hive_state)
        end
        assert_match(slug, error.message)
        assert File.directory?(folder), "folder must survive — that is what forces the re-raise"
      ensure
        File.singleton_class.define_method(:mtime, original)
      end
    end
  end

  def test_collect_rows_reraises_enoent_from_state_file_mtime_when_folder_survives
    # Companion to test_collect_rows_reraises_enoent_when_folder_survives,
    # pinning the SAME re-raise contract at the line-434 state-file TOCTOU
    # (File.exist?(state_file) then File.mtime(state_file)) — the exact in-folder
    # read the rescue comment names as the intended re-raise path. A state read
    # failing inside a folder that did NOT move stages must propagate (exit-70),
    # not be swallowed as a stage move.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "state-corrupt-260611-abcd"
      folder = create_finalize_ready_task(hive_state, slug)
      state_basename = File.basename(Hive::Task.new(folder).state_file)

      # Raise ENOENT only for the state-file mtime (basename == pr.md), leaving
      # the folder mtime at :433 (basename == slug) intact — so the ENOENT can
      # only originate at the :434 state-file read while the folder survives.
      original = File.singleton_class.instance_method(:mtime)
      File.define_singleton_method(:mtime) do |path|
        raise Errno::ENOENT, path.to_s if File.basename(path.to_s) == state_basename

        original.bind(File).call(path)
      end
      begin
        error = assert_raises(Errno::ENOENT) do
          Hive::Commands::Status.new.send(:collect_rows, hive_state)
        end
        assert_match(state_basename, error.message)
        assert File.directory?(folder), "folder must survive — that is what forces the re-raise"
      ensure
        File.singleton_class.define_method(:mtime, original)
      end
    end
  end

  def test_drop_transient_stage_moves_leaves_unique_slug_rows_untouched
    # The `return rows if duplicated_slugs.empty?` early-exit must hand back the
    # exact same array — no rejection pass — when no slug collides, even if some
    # folders happen not to exist on disk. assert_same pins the branch precisely:
    # the reject fallthrough would return a *new* array.
    cmd = Hive::Commands::Status.new
    rows = [
      { slug: "alpha-260611-abcd", folder: "/nonexistent/4-execute/alpha-260611-abcd" },
      { slug: "beta-260611-abcd", folder: "/nonexistent/6-review/beta-260611-abcd" }
    ]

    assert_same rows, cmd.send(:drop_transient_stage_moves, rows)
  end

  def test_drop_transient_stage_moves_returns_zero_rows_when_both_duplicate_folders_vanish
    # Double-race: a slug is duplicated across two stages but BOTH folders are
    # already gone by the time we dedup (old folder renamed away, new folder also
    # removed). drop_transient_stage_moves rejects both -> zero rows, no error.
    # This is the plan's accepted "vanish-to-zero" Risk; lock it so a future
    # change can't turn it into a crash or a resurrected stale row.
    cmd = Hive::Commands::Status.new
    slug = "double-race-260611-abcd"
    rows = [
      { slug: slug, folder: "/nonexistent/8-finalize/#{slug}" },
      { slug: slug, folder: "/nonexistent/9-done/#{slug}" }
    ]

    assert_empty cmd.send(:drop_transient_stage_moves, rows)
  end

  def test_drop_transient_stage_moves_keeps_only_surviving_row_in_three_member_group
    # drop_transient_stage_moves reject-filters EVERY duplicate-slug row whose
    # folder is gone, with no "keep exactly one" special case. A 3-member group
    # (two vanished folders + one survivor) must collapse to exactly the
    # survivor — pinning the count-agnostic behaviour against a future "keep the
    # first/last duplicate" rewrite that the 2-member tests would not catch.
    with_tmp_dir do |project_root|
      slug = "triple-race-260611-abcd"
      survivor_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      FileUtils.mkdir_p(survivor_folder)
      rows = [
        { slug: slug, stage: "4-execute", folder: "/nonexistent/4-execute/#{slug}" },
        { slug: slug, stage: "8-finalize", folder: "/nonexistent/8-finalize/#{slug}" },
        { slug: slug, stage: "6-review", folder: survivor_folder }
      ]

      result = Hive::Commands::Status.new.send(:drop_transient_stage_moves, rows)

      assert_equal 1, result.size, "only the surviving row should remain"
      assert_equal survivor_folder, result.first.fetch(:folder)
      assert_equal "6-review", result.first.fetch(:stage)
    end
  end

  def test_json_payload_never_emits_transient_duplicate_for_stage_move_race
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "archive-race-260611-cdef"
      old_folder = create_finalize_ready_task(hive_state, slug)
      new_folder = File.join(hive_state, "stages", "9-done", slug)
      FileUtils.mkdir_p(File.dirname(new_folder))

      payload = StatusRaceCommand.new(
        old_folder: old_folder,
        new_folder: new_folder,
        rename_before_stage: "9-done"
      ).json_payload([
        status_project(project_root, hive_state)
      ])
      tasks = payload.fetch("projects").first.fetch("tasks")
      race_tasks = tasks.select { |task| task.fetch("slug") == slug }

      assert_equal 1, race_tasks.size
      assert_equal "9-done", race_tasks.first.fetch("stage")
      refute_equal Hive::Schemas::TaskActionKind::ERROR, race_tasks.first.fetch("action")
    end
  end

  def test_collect_rows_preserves_genuine_stage_collision_and_disambiguates_generic_command
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "genuine-collision-260611-abcd"
      execute_folder = File.join(hive_state, "stages", "4-execute", slug)
      review_folder = File.join(hive_state, "stages", "6-review", slug)
      FileUtils.mkdir_p(execute_folder)
      FileUtils.mkdir_p(review_folder)
      File.write(File.join(execute_folder, "task.md"), "<!-- EXECUTE_STALE -->\n")
      File.write(File.join(review_folder, "task.md"), "<!-- REVIEW_COMPLETE -->\n")

      tasks = Hive::Commands::Status.new.json_payload([
        status_project(project_root, hive_state)
      ]).fetch("projects").first.fetch("tasks").select { |task| task.fetch("slug") == slug }
      execute = tasks.find { |task| task.fetch("stage") == "4-execute" }
      review = tasks.find { |task| task.fetch("stage") == "6-review" }

      assert_equal [ "4-execute", "6-review" ], tasks.map { |task| task.fetch("stage") }.sort
      assert_equal "hive findings #{slug} --stage 4-execute", execute.fetch("suggested_command")
      # Symmetric guard on the higher-stage survivor: :review_complete routes to
      # the `artifacts` workflow verb, which carries --from for idempotency.
      assert_equal "hive artifacts #{slug} --from 6-review", review.fetch("suggested_command")
    end
  end

  def test_existing_finalize_folder_without_pr_md_stays_error
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "corrupt-finalize-260611-abcd"
      folder = File.join(hive_state, "stages", "8-finalize", slug)
      FileUtils.mkdir_p(folder)

      task = Hive::Commands::Status.new.json_payload([
        status_project(project_root, hive_state)
      ]).fetch("projects").first.fetch("tasks").find { |candidate| candidate.fetch("slug") == slug }

      assert_equal "8-finalize", task.fetch("stage")
      assert_equal Hive::Schemas::TaskActionKind::ERROR, task.fetch("action")
    end
  end

  def test_live_task_lock_overrides_marker_derived_action
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "6-review", "reviewing-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "slug" => "reviewing-task-260524-abcd",
        "stage" => "review"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "reviewing-task-260524-abcd" }

      assert_equal :execute_complete, row.fetch(:marker_name)
      assert_equal true, row.fetch(:live_task_lock)
      assert_equal "agent_running", row.fetch(:action_key)
      assert_equal "Agent running", row.fetch(:action_label)
      assert_nil row.fetch(:suggested_command)
      assert_match(/run_lock pid=#{Process.pid}/, row.fetch(:state_label))
    end
  end

  def test_agent_working_with_live_runner_lock_is_not_rendered_stale_before_claude_pid
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "5-open-pr", "opening-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "pr.md"), "<!-- AGENT_WORKING -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "slug" => "opening-task-260524-abcd",
        "stage" => "open-pr"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "opening-task-260524-abcd" }

      assert_equal :agent_working, row.fetch(:marker_name)
      assert_equal true, row.fetch(:live_task_lock)
      assert_nil row.fetch(:claude_pid)
      assert_equal "agent_running", row.fetch(:action_key)
      assert_equal "Agent running", row.fetch(:action_label)
      assert_nil row.fetch(:suggested_command)
      assert_match(/run_lock pid=#{Process.pid}/, row.fetch(:state_label))
    end
  end

  def test_dead_task_lock_does_not_override_marker_derived_action
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "ready-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => 12_345,
        "process_start_time" => "old-start",
        "slug" => "ready-task-260524-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      cmd.define_singleton_method(:pid_alive?) { |_pid| false }
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "ready-task-260524-abcd" }

      assert_equal false, row.fetch(:live_task_lock)
      assert_equal "ready_to_open_pr", row.fetch(:action_key)
      assert_equal "hive open-pr ready-task-260524-abcd --from 4-execute", row.fetch(:suggested_command)
    end
  end

  def test_live_task_lock_with_recorded_but_unreadable_live_start_time_is_stale
    # PID-reuse defense: a .lock written with a recorded process_start_time
    # whose live counterpart can no longer be read (containerised /proc,
    # PID has since exited and the kernel reused it) must be treated as
    # stale. Otherwise we'd misclassify a freshly-reused PID as live.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "phantom-task-260525-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => "recorded-but-unreadable-now",
        "slug" => "phantom-task-260525-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      rows = nil
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { nil }) do
        rows = cmd.send(:annotate_actions,
                        cmd.send(:collect_rows, hive_state),
                        { "name" => "demo" },
                        1,
                        with_diagnostic: false)
      end
      row = rows.find { |candidate| candidate[:slug] == "phantom-task-260525-abcd" }

      assert_equal false, row.fetch(:live_task_lock),
                   "recorded start time + nil live start time must be classified as stale (PID may have been reused)"
    end
  end

  def test_live_task_lock_with_legacy_lock_omitting_process_start_time_is_live
    # Backwards-compat: .lock files written before the start-time guard
    # was introduced have no `process_start_time` key. Treat those as
    # live when the PID is alive — the alternative (treating legacy locks
    # as stale) would auto-classify in-flight runs from older hive
    # versions as recoverable, racing the daemon's auto-heal.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "legacy-task-260525-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "slug" => "legacy-task-260525-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "legacy-task-260525-abcd" }

      assert_equal true, row.fetch(:live_task_lock),
                   "legacy lock without process_start_time must stay live while PID is alive"
      assert_equal "agent_running", row.fetch(:action_key)
    end
  end

  def test_live_task_lock_with_mismatched_process_start_time_is_treated_as_stale
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "executing-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => "wrong-start-1234",
        "slug" => "executing-task-260524-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "executing-task-260524-abcd" }

      assert_equal false, row.fetch(:live_task_lock)
      assert_equal "ready_to_open_pr", row.fetch(:action_key)
    end
  end

  # Generic and differentiated needs-input labels must sort with the actionable
  # rows, ABOVE "Error" — a regression dropping any entry from ACTION_LABEL_ORDER
  # gives it index `length` (an unknown label) and silently sinks those status
  # rows below "Error". `action_labels` is the live sorter consumed by
  # render_project and the TUI snapshot, so pin the labels here.
  def test_action_labels_sorts_actionable_waiting_labels_above_error
    cmd = Hive::Commands::Status.new
    rows = [
      { action_label: "Error" },
      { action_label: "Ready to advance" },
      { action_label: "Ready to run" },
      { action_label: "Answer questions" },
      { action_label: "Review plan draft" },
      { action_label: "Needs your input" },
      { action_label: "Needs review decision" },
      { action_label: "Confirm finalize" }
    ]

    sorted = cmd.send(:action_labels, rows)

    [ "Ready to run", "Ready to advance", "Answer questions", "Review plan draft",
      "Needs your input", "Needs review decision", "Confirm finalize" ].each do |label|
      assert_operator sorted.index(label), :<, sorted.index("Error"),
                      "#{label.inspect} rows must sort above 'Error'"
    end
  end

  def test_action_label_order_covers_every_task_action_label
    action_labels = Hive::TaskAction::ACTIONS.values.map { |action| action.fetch(:label) }.uniq

    assert_empty action_labels - Hive::Commands::Status::ACTION_LABEL_ORDER
  end

  def test_render_project_skips_empty_action_label_groups
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "1-inbox", "queued-task-260522-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "idea.md"), "Idea\n")
      cmd = Hive::Commands::Status.new
      cmd.define_singleton_method(:action_labels) { |_rows| [ "Not present" ] }

      out, = capture_io do
        cmd.send(:render_project, { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state },
                 project_count: 1)
      end

      assert_includes out, "demo"
      refute_includes out, "queued-task-260522-abcd"
    end
  end

  def test_render_project_prints_pr_number_after_id_and_dash_when_missing
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      review = File.join(hive_state, "stages", "6-review", "review-task-260615-abcd")
      brainstorm = File.join(hive_state, "stages", "2-brainstorm", "brainstorm-task-260615-abcd")
      FileUtils.mkdir_p(review)
      FileUtils.mkdir_p(brainstorm)
      Hive::TaskMeta.write(review, id: 12, slug: "review-task-260615-abcd", display_name: "Fix Login")
      Hive::TaskMeta.write(brainstorm, id: 13, slug: "brainstorm-task-260615-abcd", display_name: "No PR Yet")
      File.write(File.join(review, "task.md"), "<!-- REVIEW_WAITING escalations=1 pass=1 -->\n")
      File.write(File.join(review, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/example/repo/pull/561
        ---
      MD
      File.write(File.join(brainstorm, "brainstorm.md"), "<!-- WAITING -->\n")

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_match(/#12\s+#561\s+Fix Login/, out)
      assert_match(/#13\s+—\s+No PR Yet/, out)
      refute_match(/\e\]8;;/, out, "captured non-tty status output must not emit OSC 8 bytes")
    end
  end

  # Guards the High alignment bug: in a TTY the PR token is wrapped in
  # ~45 invisible OSC 8 escape bytes, so padding must be computed on the
  # *visible* width (plan U3: pad first, splice the link after). We assert
  # both that the link is emitted AND that stripping the escapes yields
  # output byte-identical to the non-tty render — i.e. column alignment is
  # preserved. Without this every status text test runs under capture_io
  # (non-tty), so the enabled OSC 8 path is never exercised.
  def test_render_project_tty_keeps_column_alignment_while_emitting_osc8_link
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      review = File.join(hive_state, "stages", "6-review", "review-task-260615-abcd")
      FileUtils.mkdir_p(review)
      Hive::TaskMeta.write(review, id: 12, slug: "review-task-260615-abcd", display_name: "Fix Login")
      File.write(File.join(review, "task.md"), "<!-- REVIEW_WAITING escalations=1 pass=1 -->\n")
      File.write(File.join(review, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/example/repo/pull/561
        ---
      MD

      non_tty, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      tty, = capture_io do
        $stdout.define_singleton_method(:tty?) { true }
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_match(%r{\e\]8;;https://github.com/example/repo/pull/561\e\\#561\e\]8;;\e\\}, tty,
                   "tty render must emit the OSC 8 hyperlink for the PR token")

      stripped = tty.gsub(/\e\]8;;[^\e]*\e\\/, "")
      assert_equal non_tty, stripped,
                   "stripping OSC 8 escapes from the tty render must reproduce the non-tty " \
                   "layout exactly — visible column widths must not shift"
    end
  end

  def test_archive_mode_prints_pr_number_after_id
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "9-done", "archived-task-260615-abcd")
      FileUtils.mkdir_p(folder)
      Hive::TaskMeta.write(folder, id: 9, slug: "archived-task-260615-abcd", display_name: "Archived Task")
      File.write(File.join(folder, "task.md"), "<!-- COMPLETE -->\n")
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/example/repo/pull/561
        ---
      MD

      out, = capture_io do
        Hive::Commands::Status.new(archive: true).send(:render_project, status_project(project_root, hive_state),
                                                       project_count: 1)
      end

      assert_match(/#9\s+#561\s+Archived Task/, out)
    end
  end

  def test_render_project_hides_old_clean_archived_rows_and_prints_summary
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "old-archived-260604-abcd", marker: "COMPLETE", age_days: 5)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      refute_includes out, "old-archived-260604-abcd"
      assert_includes out, "… and 1 archived >3d ago (hive archive to view)"
      refute_includes out, "no active tasks"
    end
  end

  def test_render_project_keeps_recent_archived_rows_without_summary
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "recent-archived-260604-abcd", marker: "COMPLETE", age_days: 1)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "Archived"
      assert_includes out, "recent-archived-260604-abcd"
      refute_includes out, "archived >3d ago"
    end
  end

  def test_render_project_hides_old_archived_rows_with_unresolved_markers
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "errored-archived-260604-abcd", marker: "ERROR", age_days: 10)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      refute_includes out, "Error"
      refute_includes out, "errored-archived-260604-abcd"
      assert_includes out, "… and 1 archived >3d ago (hive archive to view)"
    end
  end

  def test_render_project_reports_hidden_count_with_mixed_archived_rows
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      12.times do |idx|
        create_status_task(hive_state, "9-done", "old-archived-#{idx}-260604-abcd", marker: "COMPLETE", age_days: 5)
      end
      create_status_task(hive_state, "9-done", "recent-archived-260604-abcd", marker: "COMPLETE", age_days: 1)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "recent-archived-260604-abcd"
      refute_includes out, "old-archived-0-260604-abcd"
      assert_includes out, "… and 12 archived >3d ago (hive archive to view)"
    end
  end

  def test_render_project_never_hides_old_non_archived_rows
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "4-execute", "old-execute-260604-abcd", marker: "EXECUTE_COMPLETE", age_days: 99)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "old-execute-260604-abcd"
      refute_includes out, "archived >3d ago"
    end
  end

  def test_archive_mode_lists_all_done_rows_without_age_cutoff
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "old-archived-260604-abcd", marker: "COMPLETE", age_days: 10)
      create_status_task(hive_state, "9-done", "recent-archived-260604-abcd", marker: "COMPLETE", age_days: 0)
      create_status_task(hive_state, "4-execute", "active-task-260604-abcd", marker: "EXECUTE_COMPLETE", age_days: 10)

      out, = capture_io do
        Hive::Commands::Status.new(archive: true).send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "Archived"
      assert_includes out, "old-archived-260604-abcd"
      assert_includes out, "recent-archived-260604-abcd"
      refute_includes out, "active-task-260604-abcd"
      refute_includes out, "archived >3d ago"
    end
  end

  def test_archive_mode_json_filters_to_done_rows
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "old-archived-260604-abcd", marker: "COMPLETE", age_days: 10)
      create_status_task(hive_state, "4-execute", "active-task-260604-abcd", marker: "EXECUTE_COMPLETE", age_days: 10)

      payload = Hive::Commands::Status.new(json: true, archive: true).json_payload([
        status_project(project_root, hive_state)
      ])
      slugs = payload.fetch("projects").first.fetch("tasks").map { |task| task.fetch("slug") }

      assert_equal [ "old-archived-260604-abcd" ], slugs
    end
  end

  def test_archive_mode_empty_project_prints_friendly_message
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))

      out, = capture_io do
        Hive::Commands::Status.new(archive: true).send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "no archived tasks"
    end
  end

  def test_status_private_helpers_cover_error_and_fallback_paths
    cmd = Hive::Commands::Status.new
    assert_equal [], cmd.send(:detect_legacy_stage_dirs, "/tmp/no-such-hive-state")
    assert_match(/h ago/, cmd.send(:humanise_age, Time.now - 7_200))
    assert_match(/d ago/, cmd.send(:humanise_age, Time.now - 172_800))
    marker = Hive::Markers::State.new(
      name: :error,
      attrs: { "detail" => "line 1\nline 2", "marker_id" => "err-123" },
      raw: nil
    )
    assert_equal "error detail=line 1 line 2", cmd.send(:label_for, marker)
    assert_equal Hive::Schemas::StatusErrorKind::ERROR,
                 cmd.send(:error_kind_for, Hive::Error.new("generic"))

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert_equal true, cmd.send(:pid_alive?, 12_345)
    end

    holder = { "pid" => 12_345, "process_start_time" => "recorded" }
    cmd.define_singleton_method(:pid_alive?) { |_pid| true }
    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { raise RuntimeError, "blocked" }) do
      _out, err = capture_io do
        assert_nil cmd.send(:live_task_lock_holder, holder)
      end
      assert_includes err, "hive: status: failed to check liveness"
      assert_includes err, "RuntimeError: blocked"
    end

    with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { { "agent_marker_grace_sec" => "not-int" } }) do
      _out, err = capture_io do
        assert_equal Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC,
                     cmd.send(:agent_marker_grace_sec_from_config)
      end
      assert_includes err, "invalid daemon.agent_marker_grace_sec"
    end

    with_tmp_dir do |dir|
      task = Struct.new(:folder).new(dir)
      # Array-shaped (parseable but not a Hash) → silently nil, no warn.
      File.write(File.join(dir, ".lock"), "- not\n- a\n- hash\n")
      _out, err = capture_io do
        assert_nil cmd.send(:claude_pid_from_lock, cmd.send(:task_lock_holder, task))
      end
      assert_equal "", err,
                   "a parseable non-Hash .lock must not trigger the corrupt-lock warn"

      # Malformed YAML → rescue path, must emit warn so the degraded
      # classification ("no lock" despite something being on disk) is
      # observable in operator output.
      File.write(File.join(dir, ".lock"), "[")
      _out, err = capture_io do
        assert_nil cmd.send(:claude_pid_from_lock, cmd.send(:task_lock_holder, task))
      end
      assert_includes err, "hive: status: failed to read .lock"
      assert_includes err, "Psych"
    end
  end

  # The deliberate StandardError→SystemCallError narrowing in pr_url_for:
  # a non-ENOENT I/O fault reading pr.md (here EACCES) must warn — so the
  # degraded "no PR" is observable — and degrade to nil rather than crash
  # this poll-heavy surface. Mirrors the .lock EACCES discipline above.
  def test_pr_url_for_warns_and_degrades_on_non_enoent_system_call_error
    cmd = Hive::Commands::Status.new
    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "6-review", "eacces-task-260615-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "pr.md"), "---\npr_url: https://github.com/example/repo/pull/1\n---\n")
      task = Hive::Task.new(folder)

      with_replaced_singleton_method(Hive::Gh, :pr_frontmatter, ->(_path) { raise Errno::EACCES }) do
        _out, err = capture_io do
          assert_nil cmd.send(:pr_url_for, task),
                     "a non-ENOENT I/O fault reading pr.md must degrade to nil, not crash"
        end
        assert_includes err, "hive: status: failed to read pr.md"
        assert_includes err, "Errno::EACCES"
      end
    end
  end

  def test_pr_url_for_degrades_quietly_when_pr_md_vanishes_mid_scan
    cmd = Hive::Commands::Status.new
    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "6-review", "missing-pr-260615-abcd")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)

      with_replaced_singleton_method(Hive::Gh, :pr_frontmatter, ->(_path) { raise Errno::ENOENT }) do
        _out, err = capture_io do
          assert_nil cmd.send(:pr_url_for, task),
                     "a disappearing pr.md must degrade to no PR, not crash status"
        end
        assert_equal "", err
      end
    end
  end

  def test_project_name_and_error_envelope_fallback_branches
    cmd = Hive::Commands::Status.new

    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "1-inbox", "named-task-260522-abcd")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ { "name" => "registered", "path" => project_root } ] }) do
        assert_equal "registered", cmd.send(:project_name_for, task)
      end
    end

    with_replaced_singleton_method(JSON, :generate, ->(_payload) { raise JSON::GeneratorError, "nope" }) do
      out, = capture_io { cmd.send(:emit_error_envelope, Hive::Error.new("boom")) }
      assert_equal "", out
    end
  end

  def test_non_json_internal_error_does_not_emit_error_envelope
    cmd = Hive::Commands::Status.new(json: false)
    cmd.define_singleton_method(:do_call) { raise RuntimeError, "boom" }

    out, err, status = with_captured_exit { cmd.call }

    assert_equal Hive::ExitCodes::SOFTWARE, status
    assert_equal "", out
    assert_includes err, "internal error: RuntimeError: boom"
  end

  def test_emit_diagnose_result_text_branches
    cmd = Hive::Commands::Status.new
    task = Struct.new(:slug, :folder).new("diagnose-task-260522-abcd", "/tmp/diagnose-task")

    out, = capture_io do
      cmd.send(:emit_diagnose_result, task, { "summary" => "summary", "detail" => "detail" }, "/tmp/diagnostic.md")
    end
    assert_includes out, "wrote /tmp/diagnostic.md"

    out, = capture_io do
      cmd.send(:emit_diagnose_result, task, { "summary" => "summary", "detail" => "detail" }, nil)
    end
    assert_includes out, "summary"
    assert_includes out, "detail"

    out, = capture_io { cmd.send(:emit_diagnose_result, task, nil, nil) }
    assert_includes out, "no diagnostic evidence on disk"
  end

  def test_diagnose_safe_mtime_degrades_for_missing_source_path
    cmd = Hive::Commands::Status.new

    assert_nil cmd.send(:safe_mtime, "/tmp/missing-diagnose-evidence-source")
  end

  def test_invalid_task_row_degrades_when_folder_mtime_is_unreadable
    cmd = Hive::Commands::Status.new
    folder = "/tmp/missing-invalid-task"
    original = File.method(:mtime)

    row = with_replaced_singleton_method(File, :mtime, lambda { |candidate|
      raise Errno::ENOENT, "gone" if candidate == folder

      original.call(candidate)
    }) do
      cmd.send(:invalid_task_row, stage: "1-inbox", slug: "bad-task-260620-abcd",
                                   folder: folder, message: "bad workflow")
    end

    assert_equal :error, row.fetch(:marker_name)
    assert_equal "invalid_task", row.fetch(:marker_attrs).fetch("reason")
    assert_kind_of Time, row.fetch(:folder_mtime)
  end

  private

  def status_project(project_root, hive_state)
    { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
  end

  def create_status_task(hive_state, stage, slug, marker:, age_days:)
    folder = File.join(hive_state, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "task.md")
    File.write(state_file, "<!-- #{marker} -->\n")
    old = Time.now - (age_days * 86_400)
    File.utime(old, old, state_file)
    File.utime(old, old, folder)
    folder
  end

  def write_status_task(hive_state, stage, slug, state_file:, marker:)
    folder = File.join(hive_state, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, state_file), "<!-- #{marker} -->\n")
    folder
  end

  def create_finalize_ready_task(hive_state, slug)
    folder = File.join(hive_state, "stages", "8-finalize", slug)
    pr_url = "https://github.com/example/demo/pull/1"
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "task.md"), "# Task\n<!-- COMPLETE -->\n")
    File.write(File.join(folder, "pr.md"), <<~MD)
      ---
      pr_url: #{pr_url}
      ---
      # Pull request
      <!-- COMPLETE pr_url=#{pr_url} is_draft=false -->
    MD
    folder
  end

  class StatusRaceCommand < Hive::Commands::Status
    # The double created for the vanish-during-read mode, so tests can assert it
    # actually fired (see VanishAfterDirectoryCheckPath#renamed?). nil in the
    # rename-before-stage mode.
    attr_reader :vanish_double

    def initialize(old_folder:, new_folder:, rename_before_stage: nil, vanish_during_read_stage: nil)
      super()
      unless rename_before_stage.nil? ^ vanish_during_read_stage.nil?
        raise ArgumentError,
              "pass exactly one of rename_before_stage: or vanish_during_read_stage:"
      end

      @old_folder = old_folder
      @new_folder = new_folder
      @rename_before_stage = rename_before_stage
      @vanish_during_read_stage = vanish_during_read_stage
      @renamed = false
      @vanish_double = nil
    end

    def stage_task_entries(stage_dir)
      stage = File.basename(stage_dir)
      rename_once if stage == @rename_before_stage
      entries = super
      return entries unless stage == @vanish_during_read_stage

      entries.map do |entry|
        if entry == @old_folder
          @vanish_double = VanishAfterDirectoryCheckPath.new(entry, @new_folder)
        else
          entry
        end
      end
    end

    private

    def rename_once
      return if @renamed

      FileUtils.mkdir_p(File.dirname(@new_folder))
      File.rename(@old_folder, @new_folder)
      @renamed = true
    end
  end

  # Coerces to a path string but vanishes the folder mid-read to reproduce the
  # stage-move race. `File.*` coerce their argument via the `to_path` protocol
  # (not `to_str`), so the rename is timed by a `to_path` call count. The only
  # load-bearing fact is that the rename fires on the FIRST coercion AFTER the
  # `File.directory?(entry)` existence guard (status.rb:423) — the exact
  # downstream count is NOT load-bearing:
  #   - call 1 is the directory? guard itself (folder still present, so the row
  #     loop is entered);
  #   - call 2 is `File.basename(entry)` slug extraction (status.rb:425), where
  #     `@calls > 1` fires the rename;
  #   - the row loop then coerces `entry` again — first `Task.new(entry)`'s
  #     `File.expand_path` (a pure string op, no disk hit), then finally
  #     `File.mtime(entry)` (status.rb:433), where the now-renamed folder
  #     surfaces the ENOENT (`File.mtime` itself coerces twice; the precise
  #     tally past call 2 does not matter).
  # Because only the post-guard timing matters, a coercion-count shift from a
  # refactor stays harmless as long as some `File.*(entry)` call still follows
  # the rename; StatusRaceCommand#vanish_double + #renamed? (and
  # test_vanish_after_directory_check_path_renames_on_second_to_path_call) let
  # the suite fail loudly if the rename silently stops firing. Only `to_path`
  # participates in the rename dance; `to_s` is an inert fallback for
  # inspection/logging and never triggers the vanish (omitting `to_str` is
  # deliberate for the same reason).
  class VanishAfterDirectoryCheckPath
    def initialize(path, new_path)
      @path = path
      @new_path = new_path
      @calls = 0
      @renamed = false
    end

    def to_path
      @calls += 1
      rename_once if @calls > 1
      @path
    end

    def to_s
      @path
    end

    # True once the mid-read rename has actually fired. Lets tests enforce the
    # coercion-count timing rather than merely document it.
    def renamed?
      @renamed
    end

    private

    def rename_once
      return if @renamed

      FileUtils.mkdir_p(File.dirname(@new_path))
      File.rename(@path, @new_path)
      @renamed = true
    end
  end
end
