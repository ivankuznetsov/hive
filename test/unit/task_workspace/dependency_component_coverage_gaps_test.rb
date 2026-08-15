require "test_helper"
require "hive/task_workspace/dependency_component"

class TaskWorkspaceDependencyComponentCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  D = Hive::DependencyAdmission

  class BrokenContext
    def project_snapshot_layers
      raise "broken snapshot"
    end
  end

  def test_default_clock_and_outer_failure_are_bounded
    subject = Hive::TaskWorkspace::DependencyComponent.new(
      context: context(project(tasks: [])), project: "app", slug: "missing"
    )
    assert_kind_of Numeric, subject.instance_variable_get(:@monotonic_clock).call

    failed = Hive::TaskWorkspace::DependencyComponent.new(
      context: BrokenContext.new, project: "app", slug: "task",
      monotonic_clock: -> { 0.0 }
    ).call
    assert_equal "unavailable", failed.fetch("state")
    assert_equal "component_failed", failed.dig("diagnostics", 0, "reason")
  end

  def test_inventory_project_entry_and_inner_deadline_caps
    many_projects = context(
      project(name: "app", tasks: [ task("root") ]),
      project(name: "data", tasks: [ task("remote", project: "data") ])
    )
    capped = component(
      many_projects, limits: Hive::TaskWorkspace::Limits.new(dependency_projects: 1)
    ).call
    assert_includes capped.fetch("diagnostics").filter_map { |row| row["cap"] },
                    "dependency_projects"

    many_tasks = context(project(tasks: [ task("root"), task("second") ]))
    capped = component(
      many_tasks, limits: Hive::TaskWorkspace::Limits.new(dependency_entries: 1)
    ).call
    assert_includes capped.fetch("diagnostics").filter_map { |row| row["cap"] },
                    "dependency_entries"

    ticks = [ 0.0, 0.0, 3.0 ]
    deadline = component(
      many_tasks, limits: Hive::TaskWorkspace::Limits.new(dependency_deadline_seconds: 2),
      clock: -> { ticks.shift || 3.0 }
    ).call
    assert_includes deadline.fetch("diagnostics").filter_map { |row| row["cap"] },
                    "dependency_deadline_seconds"
  end

  def test_invalid_and_missing_edges_have_explicit_states
    invalid = context(project(tasks: [ task("root", depends_on: "bad::reference") ]))
    panel = component(invalid).call
    assert_includes panel.fetch("diagnostics").map { |row| row["reason"] },
                    "dependency_reference_invalid"

    missing = context(project(tasks: [ task("root", depends_on: "ghost") ]))
    panel = component(missing).call
    assert_equal "error", panel.fetch("edges").first.fetch("state")
    source = node("root")
    target = node("ghost").merge("kind" => "missing")
    assert_equal "missing", component(missing).send(:edge, source, target, nil).fetch("state")
  end

  def test_depth_edge_and_byte_caps_preserve_a_safe_component
    indexed = context(project(tasks: [
      task("a"), task("b", depends_on: "a"), task("c", depends_on: "b")
    ]))
    depth = component(
      indexed, slug: "b", limits: Hive::TaskWorkspace::Limits.new(dependency_depth: 1)
    ).call
    assert_includes depth.fetch("diagnostics").filter_map { |row| row["cap"] },
                    "dependency_depth"

    edges = component(
      indexed, slug: "b", limits: Hive::TaskWorkspace::Limits.new(dependency_edges: 1)
    ).call
    assert_includes edges.fetch("diagnostics").filter_map { |row| row["cap"] },
                    "dependency_edges"

    subject = component(indexed)
    nodes = [ node("a"), node("b") ]
    edge = {
      "id" => "edge", "from" => "a", "to" => "b", "payload" => "x" * 1_000
    }
    subject.instance_variable_set(
      :@limits, Hive::TaskWorkspace::Limits.new(dependency_bytes: 900)
    )
    accepted_nodes, accepted_edges, truncated, = subject.send(:enforce_bytes, nodes, [ edge ])
    assert truncated
    assert_empty accepted_edges
    assert accepted_nodes.any? { |item| item["kind"] == "sentinel" }

    subject.instance_variable_set(
      :@limits, Hive::TaskWorkspace::Limits.new(dependency_bytes: 750)
    )
    large_nodes = [ node("a"), node("b"), node("c").merge("payload" => "x" * 600) ]
    connected = { "id" => "edge", "from" => "a", "to" => "b" }
    accepted_nodes, accepted_edges, truncated, = subject.send(
      :enforce_bytes, large_nodes, [ connected ]
    )
    assert truncated
    assert_operator accepted_nodes.length, :<=, 2
    assert_empty accepted_edges

    subject.instance_variable_set(:@started_at, 0.0)
    subject.instance_variable_set(:@deadline, 2.0)
    subject.instance_variable_set(:@monotonic_clock, -> { 3.0 })
    diagnostics = []
    selected = subject.send(:connected_selection, "a", { "a" => node("a") }, [], diagnostics)
    assert selected.fetch(:truncated)
    assert_includes diagnostics.filter_map { |row| row["cap"] }, "dependency_deadline_seconds"
  end

  def test_git_observation_and_offending_reference_fail_soft
    indexed = context(project(tasks: [ task("root") ]))
    reader = ->(*) { raise "git unavailable" }
    panel = Hive::TaskWorkspace::DependencyComponent.new(
      context: indexed, project: "app", slug: "root",
      git_observation_reader: reader, monotonic_clock: -> { 0.0 }
    ).call
    assert_includes panel.fetch("diagnostics").map { |row| row["reason"] },
                    "git_observation_unavailable"

    subject = component(indexed)
    original = Hive::SecretPatterns.method(:redact)
    with_replaced_singleton_method(
      Hive::SecretPatterns, :redact, ->(*) { raise ArgumentError, "bad text" }
    ) do
      assert_nil subject.send(:safe_offending_ref, "relative")
    end
    assert original
  end

  private

  def component(indexed, slug: "root", limits: Hive::TaskWorkspace::Limits.new,
                clock: -> { 0.0 })
    Hive::TaskWorkspace::DependencyComponent.new(
      context: indexed, project: "app", slug: slug,
      limits: limits, monotonic_clock: clock
    )
  end

  def context(*projects)
    D::Context.new(projects: projects)
  end

  def project(name: "app", tasks: [])
    D::ProjectSnapshot.new(
      name: name, path: "/tmp/#{name}",
      repository_identity: "github.com/acme/#{name}",
      live_repository_identity: "github.com/acme/#{name}",
      dependency_gate_stage: "8-finalize", tasks: tasks, validation_error: nil
    )
  end

  def task(slug, project: "app", depends_on: nil)
    D::TaskSnapshot.new(
      project: project, slug: slug, id: nil, stage: "4-execute",
      workflow_stages: Hive::Stages::DIRS, depends_on: depends_on,
      metadata_status: :ok, metadata_error: nil,
      plan_status: :absent, plan_dependency: nil, plan_error: nil,
      folder: "/tmp/#{project}/#{slug}", validation_error: nil
    )
  end

  def node(id)
    {
      "id" => id, "kind" => "task", "project" => "app", "slug" => id,
      "task_id" => nil, "stage" => "4-execute", "root" => id == "a",
      "depends_on" => nil, "dependency_gate_stage" => "8-finalize",
      "admission" => { "state" => "clear", "blocked_by" => nil,
                       "dependency_stage" => nil, "error" => nil },
      "evidence_state" => "current", "stack" => { "state" => "unavailable" },
      "reference" => { "project" => "app", "slug" => id }
    }
  end
end
