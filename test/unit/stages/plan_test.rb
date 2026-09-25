require "test_helper"
require "hive/stages/plan"
require "hive/task_meta"

class HiveStagesPlanTest < Minitest::Test
  include HiveTestHelper

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

  # Adoption only saves an operator a copy, so a meta.yml that refuses the
  # rewrite must stay silent rather than fail the plan stage: admission still
  # reports plan_dependency_mismatch and still says what to do about it.
  def test_meta_rewrite_failure_does_not_fail_the_plan_stage
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      raising = ->(*) { raise "meta.yml is held by another writer" }

      with_replaced_singleton_method(Hive::TaskMeta, :rewrite, raising) do
        assert_nil Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))
      end

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

  def with_review_record(state:, findings:, decisions:)
    record = Object.new
    record.define_singleton_method(:state) { state }
    data = { "findings" => findings, "decisions" => decisions }
    record.define_singleton_method(:[]) { |key| data.fetch(key) }
    projection = Struct.new(:record).new(record)
    with_replaced_singleton_method(Hive::PlanReview::Projection, :load, ->(task_folder:) { projection }) do
      yield FakeTask.new(folder: "/tmp/task", slug: "task")
    end
  end

  def review_finding(fingerprint, title, order, lifecycle: "approved")
    { "fingerprint" => fingerprint, "title" => title, "classification" => "gated_auto",
      "risk" => "high", "description" => "#{title} details", "lifecycle" => lifecycle,
      "display_order" => order }
  end

  def test_blocked_review_decisions_are_carried_into_the_next_plan
    findings = [
      review_finding("prf-b", "Storage substrate", 2, lifecycle: "verified"),
      review_finding("prf-a", "Operator exit", 1),
      review_finding("prf-c", "Still open", 3, lifecycle: "open")
    ]
    decisions = [
      { "action" => "approve_finding", "target_fingerprint" => "prf-a" },
      { "action" => "answer_finding", "target_fingerprint" => "prf-b",
        "value" => { "answer" => "Use the SQLite control plane." } },
      { "action" => "raise_level", "target_fingerprint" => nil }
    ]
    with_review_record(state: "blocked", findings: findings, decisions: decisions) do |task|
      text = Hive::Stages::Plan.carried_decisions_text(task)

      assert_equal [ "Operator exit", "Storage substrate" ], text.scan(/^- (.+?) \(/).flatten
      assert_includes text, "Operator decision: approved; apply the reviewer's recommendation."
      assert_includes text, "Operator answer (follow exactly): Use the SQLite control plane."
      refute_includes text, "Still open"
    end
  end

  def test_no_decisions_are_carried_unless_the_review_is_blocked
    findings = [ review_finding("prf-a", "Operator exit", 1) ]
    decisions = [ { "action" => "approve_finding", "target_fingerprint" => "prf-a" } ]
    with_review_record(state: "awaiting_decision", findings: findings, decisions: decisions) do |task|
      assert_equal "", Hive::Stages::Plan.carried_decisions_text(task)
    end
  end

  def test_missing_review_carries_nothing
    missing = ->(task_folder:) { raise Hive::PlanReview::InvalidRecord, "no review" }
    with_replaced_singleton_method(Hive::PlanReview::Projection, :load, missing) do
      assert_equal "", Hive::Stages::Plan.carried_decisions_text(FakeTask.new(folder: "/tmp/task", slug: "task"))
    end
  end

  def test_plan_prompt_wraps_carried_decisions_as_user_supplied_data
    tag = Hive::Stages::Base.user_supplied_tag
    render = lambda do |carried|
      Hive::Stages::Base.render(
        "plan_prompt.md.erb",
        Hive::Stages::Base::TemplateBindings.new(
          project_name: "demo", task_folder: "/tmp/task", brainstorm_text: "idea",
          carried_decisions_text: carried, user_supplied_tag: tag, skill_invocation: "/plan"
        )
      )
    end

    with_decisions = render.call("- Operator exit (gated_auto, high risk; prf-a)")
    assert_includes with_decisions, "<#{tag} content_type=\"plan_review_decisions\">"
    assert_includes with_decisions, "- Operator exit (gated_auto, high risk; prf-a)"
    refute_includes render.call(""), "plan_review_decisions"
  end
end

