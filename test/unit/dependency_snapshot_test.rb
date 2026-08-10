require "test_helper"
require "hive/dependency_snapshot"
require "hive/task_meta"

# Direct coverage for the disk→resolver seam. Before this, `tasks`,
# `current_task`, `depends_on`, and `stacked_base` were exercised only
# indirectly through execute/open_pr happy-path stubs, so a regression in
# the glue (folder scanning, the meta-slug fallback, the warn-on-collapse
# path) would have slipped past every resolver-level test.
class DependencySnapshotTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :slug, :id, :depends_on, :folder, :project_root, :project_name,
    keyword_init: true
  )

  def test_tasks_reads_every_stage_folder_into_resolver_shape
    with_tmp_dir do |root|
      write_task_meta(root, "4-execute", "alpha-260618-aaaa", id: 1)
      write_task_meta(root, "8-finalize", "beta-260618-bbbb", id: 2)

      tasks = Hive::DependencySnapshot.tasks(root)
      alpha = tasks.find { |t| t[:slug] == "alpha-260618-aaaa" }
      beta = tasks.find { |t| t[:slug] == "beta-260618-bbbb" }

      refute_nil alpha, "every stage folder must surface in the snapshot"
      assert_equal 1, alpha[:id]
      assert_equal "4-execute", alpha[:stage]
      assert_equal 4, alpha[:stage_index]
      assert_equal 8, beta[:stage_index]
    end
  end

  def test_tasks_skips_non_directory_entries
    with_tmp_dir do |root|
      stage_dir = File.join(root, ".hive-state", "stages", "4-execute")
      FileUtils.mkdir_p(stage_dir)
      FileUtils.touch(File.join(stage_dir, ".DS_Store"))
      write_task_meta(root, "4-execute", "real-task", id: 1)

      slugs = Hive::DependencySnapshot.tasks(root).map { |t| t[:slug] }
      assert_includes slugs, "real-task"
      refute_includes slugs, ".DS_Store", "stray files under a stage dir must be skipped"
    end
  end

  def test_tasks_falls_back_to_folder_name_when_meta_slug_absent
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".hive-state", "stages", "4-execute", "no-meta-task"))

      row = Hive::DependencySnapshot.tasks(root).find { |t| t[:slug] == "no-meta-task" }
      refute_nil row, "folder name is the fallback slug when meta.yml is absent"
      assert_nil row[:id]
    end
  end

  def test_current_task_and_depends_on_project_task_fields
    task = FakeTask.new(slug: "dependent", id: 7, depends_on: "base", folder: "/x", project_root: "/x")

    assert_equal({ slug: "dependent", id: 7 }, Hive::DependencySnapshot.current_task(task))
    assert_equal "base", Hive::DependencySnapshot.depends_on(task)
  end

  def test_stacked_base_returns_prerequisite_slug_when_resolvable
    with_tmp_dir do |root|
      write_task_meta(root, "8-finalize", "base-task", id: 1)
      task = FakeTask.new(slug: "dependent", id: 2, depends_on: "base-task",
                          folder: execute_folder(root, "dependent"), project_root: root)

      assert_equal "base-task", Hive::DependencySnapshot.stacked_base(task, "main")
    end
  end

  def test_stacked_base_returns_nil_without_dependency
    with_tmp_dir do |root|
      task = FakeTask.new(slug: "solo", id: 1, depends_on: nil,
                          folder: execute_folder(root, "solo"), project_root: root)

      assert_nil Hive::DependencySnapshot.stacked_base(task, "main")
    end
  end

  def test_stacked_base_warns_and_returns_nil_for_unresolvable_dependency
    with_tmp_dir do |root|
      task = FakeTask.new(slug: "dependent", id: 2, depends_on: "ghost-task",
                          folder: execute_folder(root, "dependent"), project_root: root)

      result = nil
      _out, err = capture_io do
        result = Hive::DependencySnapshot.stacked_base(task, "main")
      end

      assert_nil result, "an unresolvable dependency collapses to the default (nil base_override)"
      assert_match(/did not resolve to a stacked base/, err,
                   "a silently collapsed stack request must leave a stderr breadcrumb")
    end
  end

  def test_stacked_base_does_not_treat_cross_project_dependency_as_branch_base
    with_tmp_dir do |root|
      task = FakeTask.new(slug: "dependent", id: 2, depends_on: "other:base-task",
                          folder: execute_folder(root, "dependent"), project_root: root)

      result = nil
      _out, err = capture_io { result = Hive::DependencySnapshot.stacked_base(task, "main") }

      assert_nil result
      assert_match(/scheduling-only/, err)
    end
  end

  def test_stacked_base_warns_and_returns_nil_for_invalid_dependency
    with_tmp_dir do |root|
      task = FakeTask.new(
        slug: "dependent", id: 2, depends_on: "too:many:parts",
        folder: execute_folder(root, "dependent"), project_root: root
      )

      result = nil
      _out, err = capture_io { result = Hive::DependencySnapshot.stacked_base(task, "main") }

      assert_nil result
      assert_match(/invalid depends_on/, err)
    end
  end

  def test_admission_fingerprint_hashes_the_current_task_verdict
    with_tmp_dir do |root|
      slug = "independent-task"
      write_task_meta(root, "4-execute", slug, id: 1)
      project = File.basename(root)
      task = FakeTask.new(slug: slug, id: 1, folder: execute_folder(root, slug),
                          project_root: root, project_name: project)
      registry_entries = [
        { "name" => project, "path" => root, "repository_identity" => nil }
      ]

      fingerprint = Hive::DependencySnapshot.admission_fingerprint(
        task, registry_entries: registry_entries
      )
      expected_payload = [
        "hive-dependency-admission-v1", project, slug,
        "clear", "", "", "", "", ""
      ]

      assert_equal Digest::SHA256.hexdigest(JSON.generate(expected_payload)), fingerprint
    end
  end

  def test_admission_context_preserves_corrupt_metadata_as_an_error
    with_tmp_dir do |root|
      slug = "corrupt-task"
      folder = File.join(root, ".hive-state", "stages", "4-execute", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "depends_on: [unterminated\n")

      context = Hive::DependencySnapshot.admission_context([
        { "name" => File.basename(root), "path" => root, "repository_identity" => nil }
      ])
      verdict = context.verdict(project: File.basename(root), slug: slug)

      assert verdict.error?
      assert_equal "dependency_metadata_unreadable", verdict.admission_error.reason_code
    end
  end

  def test_admission_context_preserves_invalid_dependency_reference_as_its_exact_error
    with_tmp_dir do |root|
      slug = "invalid-reference-task"
      folder = File.join(root, ".hive-state", "stages", "4-execute", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "slug: #{slug}\ndepends_on: too:many:parts\n")

      context = Hive::DependencySnapshot.admission_context([
        { "name" => File.basename(root), "path" => root, "repository_identity" => nil }
      ])
      verdict = context.verdict(project: File.basename(root), slug: slug)

      assert verdict.error?
      assert_equal "dependency_reference_invalid", verdict.admission_error.reason_code
    end
  end

  def test_active_admission_context_preserves_lossless_archived_error
    with_tmp_dir do |root|
      dependent = write_task_meta(root, "4-execute", "dependent-task", id: 2)
      Hive::TaskMeta.write(
        dependent,
        id: 2,
        slug: "dependent-task",
        display_name: nil,
        depends_on: "archived-task"
      )
      project = { "name" => File.basename(root), "path" => root, "repository_identity" => nil }
      archived = write_task_meta(root, "9-done", "archived-task", id: 1)
      File.write(File.join(archived, "meta.yml"), "- invalid\n")
      full_context = Hive::DependencySnapshot.admission_context([ project ])
      fallback = Hive::DependencyAdmission::Context.new(
        projects: full_context.projects.map do |snapshot|
          snapshot.with(tasks: snapshot.tasks.select { |task| task.stage == "9-done" })
        end
      )
      context = Hive::DependencySnapshot.admission_context(
        [ project ], exclude_archived: true, fallback_context: fallback
      )
      verdict = context.verdict(project: File.basename(root), slug: "dependent-task")

      assert verdict.error?
      assert_equal "dependency_metadata_invalid", verdict.admission_error.reason_code
      assert_match(/Repair .*meta.yml/, verdict.admission_error.safe_correction)
    end
  end

  def test_active_admission_snapshot_excludes_only_rows_whose_resolved_action_is_archived
    terminal = shared_stage_terminal_workflow
    active = shared_stage_active_workflow
    Hive::Workflows::Registry.register!(terminal)
    Hive::Workflows::Registry.register!(active)
    reset_workflow_union_cache!

    with_tmp_dir do |root|
      archived = write_task_meta(root, "2-shared", "archived-shared", id: 1)
      Hive::TaskMeta.write(
        archived, id: 1, slug: "archived-shared", display_name: nil,
        workflow: terminal.id.to_s
      )
      File.write(File.join(archived, "shared.md"), "<!-- COMPLETE -->\n")

      still_active = write_task_meta(root, "2-shared", "active-shared", id: 2)
      Hive::TaskMeta.write(
        still_active, id: 2, slug: "active-shared", display_name: nil,
        workflow: active.id.to_s
      )
      File.write(File.join(still_active, "shared.md"), "<!-- COMPLETE -->\n")

      rows = Hive::DependencySnapshot.admission_tasks(
        root, {}, exclude_archived: true
      )

      assert_equal [ "active-shared" ], rows.map(&:slug)
    end
  ensure
    Hive::Workflows::Registry.reset_runtime_registrations!
    reset_workflow_union_cache!
    Hive::Workflows::Project.reset!
  end

  def test_admission_snapshot_fails_closed_when_prerequisite_moves_after_enumeration
    with_tmp_dir do |root|
      dependent = write_task_meta(root, "4-execute", "dependent-task", id: 2)
      Hive::TaskMeta.write(
        dependent, id: 2, slug: "dependent-task", display_name: nil,
        depends_on: "prerequisite-task"
      )
      prerequisite = write_task_meta(root, "9-done", "prerequisite-task", id: 1)
      rolled_back = File.join(root, ".hive-state", "stages", "7-artifacts", "prerequisite-task")
      FileUtils.mkdir_p(File.dirname(rolled_back))
      original_read = Hive::TaskMeta.method(:read_for_admission)
      moved = false
      racing_read = lambda do |folder|
        if folder == prerequisite && !moved
          moved = true
          File.rename(prerequisite, rolled_back)
        end
        original_read.call(folder)
      end

      context = with_replaced_singleton_method(Hive::TaskMeta, :read_for_admission, racing_read) do
        Hive::DependencySnapshot.admission_context([
          { "name" => File.basename(root), "path" => root, "repository_identity" => nil }
        ])
      end
      verdict = context.verdict(project: File.basename(root), slug: "dependent-task")

      assert verdict.error?
      assert_equal "dependency_validation_failed", verdict.admission_error.reason_code
      assert_match(/changed while dependency admission/, verdict.admission_error.safe_correction)
    end
  end

  def test_admission_context_resolves_live_identity_only_for_cross_project_targets
    with_tmp_dir do |home|
      app = File.join(home, "app")
      data = File.join(home, "data")
      dependent = write_task_meta(app, "4-execute", "dependent-task", id: 2)
      Hive::TaskMeta.write(
        dependent, id: 2, slug: "dependent-task", display_name: nil,
        depends_on: "data:base-task"
      )
      write_task_meta(data, "8-finalize", "base-task", id: 1)
      looked_up = []
      resolver = lambda do |root|
        looked_up << root
        "github.com/acme/data"
      end

      context = with_replaced_singleton_method(Hive::RepositoryIdentity, :current, resolver) do
        Hive::DependencySnapshot.admission_context([
          { "name" => "app", "path" => app, "repository_identity" => "github.com/acme/app" },
          { "name" => "data", "path" => data, "repository_identity" => "github.com/acme/data" }
        ])
      end

      assert context.verdict(project: "app", slug: "dependent-task").clear?
      assert_equal [ data ], looked_up
    end
  end

  def test_admission_project_fails_closed_for_bad_entries_and_configs
    with_tmp_dir do |root|
      missing_name = Hive::DependencySnapshot.admission_project({ "path" => root })
      assert_match(/KeyError/, missing_name.validation_error)

      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      config_path = File.join(state, "config.yml")
      File.write(config_path, "- not\n- a\n- mapping\n")
      non_mapping = Hive::DependencySnapshot.admission_project(
        { "name" => "app", "path" => root }
      )
      assert_match(/must contain a mapping/, non_mapping.validation_error)

      File.write(config_path, "dependency_gate_stage: [unterminated\n")
      malformed = Hive::DependencySnapshot.admission_project(
        { "name" => "app", "path" => root }
      )
      assert_match(/could not read/, malformed.validation_error)
    end
  end

  def test_admission_project_default_detects_repository_identity
    with_tmp_dir do |root|
      detected = with_replaced_singleton_method(
        Hive::RepositoryIdentity, :current, ->(path) { "identity-for:#{path}" }
      ) do
        Hive::DependencySnapshot.admission_project({ "name" => "app", "path" => root })
      end

      assert_equal "identity-for:#{root}", detected.live_repository_identity
    end
  end

  def test_cross_project_target_scan_ignores_invalid_references
    invalid = Hive::DependencyAdmission::TaskSnapshot.new(
      project: "app", slug: "bad", id: 1, stage: "4-execute",
      workflow_stages: Hive::Stages::DIRS, depends_on: "too:many:parts",
      metadata_status: :ok, metadata_error: nil, plan_status: :absent,
      plan_dependency: nil, plan_error: nil, folder: "/tmp/app/bad", validation_error: nil
    )
    project = Hive::DependencyAdmission::ProjectSnapshot.new(
      name: "app", path: "/tmp/app", repository_identity: nil,
      live_repository_identity: nil, dependency_gate_stage: "8-finalize",
      tasks: [ invalid ], validation_error: nil
    )

    assert_empty Hive::DependencySnapshot.cross_project_identity_targets([ project ])
    assert_nil Hive::DependencySnapshot.folder_identity("/definitely/missing/hive-task")
  end

  def test_enforce_admission_translates_wait_error_and_unexpected_results
    with_tmp_dir do |root|
      task = FakeTask.new(
        slug: "dependent", id: 2, depends_on: "base", folder: execute_folder(root, "dependent"),
        project_root: root, project_name: "app"
      )
      registry = [ { "name" => "app", "path" => root } ]
      wait_context = Object.new
      wait_context.define_singleton_method(:verdict) do |**_kwargs|
        Hive::DependencyAdmission::Verdict.new(
          state: :wait, blocked_by: "base", dependency_stage: "7-artifacts",
          admission_error: nil
        )
      end
      admission_context = Object.new
      admission_context.define_singleton_method(:verdict) do |**_kwargs|
        error = Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_cycle", offending_ref: "app:a -> app:a",
          safe_correction: "Break the cycle."
        )
        Hive::DependencyAdmission::Verdict.new(
          state: :error, blocked_by: nil, dependency_stage: nil, admission_error: error
        )
      end

      with_replaced_singleton_method(
        Hive::DependencySnapshot, :admission_context, ->(_entries) { wait_context }
      ) do
        error = assert_raises(Hive::DependencyWaitError) do
          Hive::DependencySnapshot.enforce_admission!(task, registry_entries: registry)
        end
        assert_equal "base", error.offending_ref
      end
      with_replaced_singleton_method(
        Hive::DependencySnapshot, :admission_context, ->(_entries) { admission_context }
      ) do
        error = assert_raises(Hive::DependencyAdmissionError) do
          Hive::DependencySnapshot.enforce_admission!(task, registry_entries: registry)
        end
        assert_equal "dependency_cycle", error.reason_code
      end
      with_replaced_singleton_method(
        Hive::DependencySnapshot, :admission_context, ->(_entries) { raise "snapshot exploded" }
      ) do
        error = assert_raises(Hive::DependencyAdmissionError) do
          Hive::DependencySnapshot.enforce_admission!(task, registry_entries: registry)
        end
        assert_equal "dependency_validation_failed", error.reason_code
        assert_match(/RuntimeError/, error.message)
      end
    end
  end

  def test_enforce_admission_rejects_missing_project_enrollment
    task = FakeTask.new(
      slug: "dependent", id: 2, depends_on: "base", folder: "/tmp/app/dependent",
      project_root: "/tmp/app", project_name: "app"
    )

    error = assert_raises(Hive::DependencyAdmissionError) do
      Hive::DependencySnapshot.enforce_admission!(task, registry_entries: [])
    end

    assert_equal "dependency_validation_failed", error.reason_code
    assert_match(/enrollment is missing or ambiguous/, error.message)
  end

  def test_workflow_generation_and_archive_classification_fail_closed
    generation_error = Hive::ConfigError.new("captured generation failed")
    snapshot = Hive::DependencySnapshot.admission_project(
      { "name" => "demo", "path" => "/project" },
      workflow_generation: generation_error
    )

    assert_includes snapshot.validation_error, "captured generation failed"
    refute Hive::DependencySnapshot.send(
      :archived_folder?, "/missing-task",
      config: {}, project_name: "demo"
    )
    assert_nil Hive::DependencySnapshot.send(
      :workflow_generation_for, {}, { "/project" => Object.new }
    )
  end

  private

  def write_task_meta(root, stage, slug, id:)
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: nil)
    folder
  end

  def execute_folder(root, slug)
    File.join(root, ".hive-state", "stages", "4-execute", slug)
  end

  def shared_stage_terminal_workflow
    Hive::Workflow.new(
      id: :terminal_shared,
      stages: [
        Hive::Workflow::Stage.new(
          name: "start", index: 1, state_file: "start.md", kind: :inert
        ),
        Hive::Workflow::Stage.new(
          name: "shared", index: 2, state_file: "shared.md", kind: :inert,
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "shared")
        )
      ]
    )
  end

  def shared_stage_active_workflow
    Hive::Workflow.new(
      id: :active_shared,
      stages: [
        Hive::Workflow::Stage.new(
          name: "start", index: 1, state_file: "start.md", kind: :inert
        ),
        Hive::Workflow::Stage.new(
          name: "shared", index: 2, state_file: "shared.md", kind: :agent,
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "shared")
        ),
        Hive::Workflow::Stage.new(
          name: "done", index: 3, state_file: "done.md", kind: :inert,
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "done")
        )
      ]
    )
  end
end
