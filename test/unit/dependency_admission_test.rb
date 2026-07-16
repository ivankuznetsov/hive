require "test_helper"
require "hive/dependency_admission"

class DependencyAdmissionTest < Minitest::Test
  D = Hive::DependencyAdmission

  def test_no_dependency_is_clear
    verdict = context(project(tasks: [ task("app", "solo") ])).verdict(project: "app", slug: "solo")

    assert verdict.clear?
    assert_nil verdict.admission_error
  end

  def test_same_project_slug_and_numeric_refs_wait_below_gate_and_release_at_gate
    %w[base 7].each do |reference|
      below = project(tasks: [ task("app", "dependent", depends_on: reference), task("app", "base", id: 7, stage: "7-artifacts") ])
      reached = project(tasks: [ task("app", "dependent", depends_on: reference), task("app", "base", id: 7, stage: "8-finalize") ])

      assert context(below).verdict(project: "app", slug: "dependent").wait?
      assert context(reached).verdict(project: "app", slug: "dependent").clear?
    end
  end

  def test_numeric_reference_never_searches_another_project
    app = project(tasks: [ task("app", "dependent", depends_on: "7") ])
    other = project(name: "other", tasks: [ task("other", "base", id: 7, stage: "9-done") ])

    assert_error context(app, other).verdict(project: "app", slug: "dependent"), "dependency_task_missing"
  end

  def test_cross_project_reference_requires_exact_project_and_repository_identity
    app = project(tasks: [ task("app", "dependent", depends_on: "data:base") ])
    data = project(name: "data", stored: "github.com/acme/data", live: "github.com/acme/data",
                   tasks: [ task("data", "base", stage: "8-finalize") ])

    assert context(app, data).verdict(project: "app", slug: "dependent").clear?

    unknown = project(tasks: [ task("app", "dependent", depends_on: "missing:base") ])
    assert_error context(unknown).verdict(project: "app", slug: "dependent"), "dependency_project_unknown"

    missing_identity = project(name: "data", stored: nil, live: nil, tasks: [ task("data", "base") ])
    assert_error context(app, missing_identity).verdict(project: "app", slug: "dependent"),
                 "dependency_repository_identity_missing"

    mismatch = project(name: "data", stored: "github.com/acme/data", live: "github.com/acme/wrong",
                       tasks: [ task("data", "base") ])
    assert_error context(app, mismatch).verdict(project: "app", slug: "dependent"),
                 "dependency_repository_mismatch"
  end

  def test_missing_self_and_complete_cross_project_cycle_fail_closed
    missing = project(tasks: [ task("app", "a", depends_on: "ghost") ])
    assert_error context(missing).verdict(project: "app", slug: "a"), "dependency_task_missing"

    self_ref = project(tasks: [ task("app", "a", depends_on: "a") ])
    assert_error context(self_ref).verdict(project: "app", slug: "a"), "dependency_self_reference"

    app = project(tasks: [ task("app", "a", depends_on: "data:b") ])
    data = project(name: "data", tasks: [ task("data", "b", depends_on: "ops:c") ])
    ops = project(name: "ops", tasks: [ task("ops", "c", depends_on: "app:a") ])
    verdict = context(app, data, ops).verdict(project: "app", slug: "a")

    assert_error verdict, "dependency_cycle"
    assert_equal "app:a -> data:b -> ops:c -> app:a", verdict.admission_error.offending_ref
  end

  def test_corrupt_upstream_and_plan_drift_fail_closed
    root = task("app", "dependent", depends_on: "base")
    corrupt = task("app", "base", metadata_status: :unreadable, metadata_error: "bad yaml")
    assert_error context(project(tasks: [ root, corrupt ])).verdict(project: "app", slug: "dependent"),
                 "dependency_metadata_unreadable"

    plan_only = task("app", "plan-only", plan_status: :ok, plan_dependency: "base")
    assert_error context(project(tasks: [ plan_only ])).verdict(project: "app", slug: "plan-only"),
                 "plan_dependency_missing"

    mismatch = task("app", "drift", depends_on: "base", plan_status: :ok, plan_dependency: "other")
    assert_error context(project(tasks: [ mismatch ])).verdict(project: "app", slug: "drift"),
                 "plan_dependency_mismatch"

    invalid = task("app", "bad-plan", plan_status: :invalid, plan_error: "bad frontmatter")
    assert_error context(project(tasks: [ invalid ])).verdict(project: "app", slug: "bad-plan"),
                 "plan_dependency_invalid"
  end

  def test_gate_unknown_and_unreachable_are_errors
    root = task("app", "dependent", depends_on: "base")
    base = task("app", "base", workflow_stages: %w[1-inbox 2-work 9-done], stage: "2-work")

    unknown = project(gate: "7-artifacts", tasks: [ root, base ])
    assert_error context(unknown).verdict(project: "app", slug: "dependent"), "dependency_gate_unknown"

    unreachable = project(gate: "8-finalize", tasks: [ root, base ])
    assert_error context(unreachable).verdict(project: "app", slug: "dependent"), "dependency_gate_unreachable"
  end

  def test_configured_done_gate_waits_through_finalize
    root = task("app", "dependent", depends_on: "base")
    finalize = project(gate: "9-done", tasks: [ root, task("app", "base", stage: "8-finalize") ])
    done = project(gate: "9-done", tasks: [ root, task("app", "base", stage: "9-done") ])

    assert context(finalize).verdict(project: "app", slug: "dependent").wait?
    assert context(done).verdict(project: "app", slug: "dependent").clear?
  end

  private

  def context(*projects)
    D::Context.new(projects: projects.flatten)
  end

  def project(name: "app", stored: "github.com/acme/#{name}", live: "github.com/acme/#{name}",
              gate: "8-finalize", tasks: [])
    D::ProjectSnapshot.new(
      name: name,
      path: "/tmp/#{name}",
      repository_identity: stored,
      live_repository_identity: live,
      dependency_gate_stage: gate,
      tasks: tasks,
      validation_error: nil
    )
  end

  def task(project, slug, id: nil, depends_on: nil, stage: "4-execute",
           workflow_stages: Hive::Stages::DIRS, metadata_status: :ok, metadata_error: nil,
           plan_status: :absent, plan_dependency: nil, plan_error: nil)
    D::TaskSnapshot.new(
      project: project,
      slug: slug,
      id: id,
      stage: stage,
      workflow_stages: workflow_stages,
      depends_on: depends_on,
      metadata_status: metadata_status,
      metadata_error: metadata_error,
      plan_status: plan_status,
      plan_dependency: plan_dependency,
      plan_error: plan_error,
      folder: "/tmp/#{project}/#{slug}",
      validation_error: nil
    )
  end

  def assert_error(verdict, code)
    assert verdict.error?, "expected admission error, got #{verdict.inspect}"
    assert_equal code, verdict.admission_error.reason_code
  end
end
