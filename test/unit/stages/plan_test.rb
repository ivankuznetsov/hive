require "test_helper"
require "hive/stages/plan"
require "hive/task_meta"

class HiveStagesPlanTest < Minitest::Test
  FakeTask = Struct.new(:folder, :slug, keyword_init: true)
  Marker = Struct.new(:name)

  def with_planned_task(plan_frontmatter, meta_depends_on: nil, slug: "cli-task")
    Dir.mktmpdir do |dir|
      Hive::TaskMeta.write(
        dir, id: 42, slug: slug, display_name: "CLI Task",
        depends_on: meta_depends_on
      )
      File.write(File.join(dir, "plan.md"), plan_frontmatter)
      yield FakeTask.new(folder: dir, slug: slug), dir
    end
  end

  def plan_doc(depends_on)
    depends_on.nil? ? "# Plan\n" : "---\ndepends_on: #{depends_on}\n---\n\n# Plan\n"
  end

  # Absence is adopted: a plan that declares a dependency must not park the
  # task on an admission error whose only remedy is copying a string by hand.
  def test_complete_plan_dependency_is_adopted_into_meta
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))

      assert_equal "rails-task", Hive::TaskMeta.read(dir)[:depends_on]
    end
  end

  # Conflict still blocks: adoption must never overwrite an operator's value,
  # so plan_dependency_mismatch stays a human decision.
  def test_existing_meta_dependency_is_never_overwritten
    with_planned_task(plan_doc("rails-task"), meta_depends_on: "operator-choice") do |task, dir|
      Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))

      assert_equal "operator-choice", Hive::TaskMeta.read(dir)[:depends_on]
    end
  end

  def test_incomplete_plan_is_not_adopted
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:waiting))

      assert_nil Hive::TaskMeta.read(dir)[:depends_on]
    end
  end

  def test_plan_without_a_dependency_changes_nothing
    with_planned_task(plan_doc(nil)) do |task, dir|
      Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))

      assert_nil Hive::TaskMeta.read(dir)[:depends_on]
    end
  end

  def test_self_dependency_is_refused
    with_planned_task(plan_doc("cli-task")) do |task, dir|
      Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))

      assert_nil Hive::TaskMeta.read(dir)[:depends_on]
    end
  end
  def test_action_for_known_markers
    assert_equal "draft_updated", Hive::Stages::Plan.action_for(:waiting)
    assert_equal "complete", Hive::Stages::Plan.action_for(:complete)
    assert_equal "error", Hive::Stages::Plan.action_for(:error)
  end

  def test_action_for_unknown_marker_stringifies_marker
    assert_equal "review_waiting", Hive::Stages::Plan.action_for(:review_waiting)
  end
end
