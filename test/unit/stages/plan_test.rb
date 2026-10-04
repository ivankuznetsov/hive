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
  # rewrite remains nonfatal, but it must stay observable and distinct from a
  # stale task skip. Admission still reports plan_dependency_mismatch.
  def test_meta_rewrite_failure_is_reported_without_failing_the_plan_stage
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      raising = ->(*, **) { raise Errno::EIO, "meta.yml is held by another writer" }

      _out, err = capture_io do
        with_replaced_singleton_method(Hive::TaskMeta, :rewrite, raising) do
          assert_nil Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))
        end
      end

      assert_nil Hive::TaskMeta.read(dir)[:depends_on]
      assert_includes err, "dependency adoption failed"
      refute_includes err, "stale task"
    end
  end

  def test_stale_dependency_adoption_is_reported_and_not_persisted
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      stale = ->(*, **) { Hive::TaskMeta::UpdateResult.new(status: :stale, value: nil) }

      _out, err = capture_io do
        with_replaced_singleton_method(Hive::TaskMeta, :rewrite, stale) do
          assert_nil Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))
        end
      end

      assert_nil Hive::TaskMeta.read(dir)[:depends_on]
      assert_includes err, "stale task"
    end
  end

  def test_dependency_adoption_does_not_recreate_a_task_deleted_before_update
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      observation = Hive::TaskMeta.observe(dir)
      FileUtils.rm_rf(dir)

      _out, err = capture_io do
        assert_nil Hive::Stages::Plan.adopt_plan_dependency!(
          task, Marker.new(:complete), observation: observation
        )
      end

      refute File.exist?(dir)
      assert_includes err, "stale task"
    ensure
      observation&.close
      FileUtils.mkdir_p(dir) if dir && !File.exist?(dir)
    end
  end

  def test_dependency_adoption_skips_a_task_missing_before_observation
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      FileUtils.rm_rf(dir)

      _out, err = capture_io do
        assert_nil Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))
      end

      refute File.exist?(dir)
      assert_includes err, "stale task"
    ensure
      FileUtils.mkdir_p(dir) if dir && !File.exist?(dir)
    end
  end

  def test_dependency_adoption_does_not_recreate_a_task_deleted_after_metadata_read
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      observation = Hive::TaskMeta.observe(dir)
      boundary_reached = false
      original = Hive::TaskMeta.method(:read_for_update!)
      delete_after_read = lambda do |folder|
        result = original.call(folder)
        boundary_reached = true
        FileUtils.rm_rf(folder)
        result
      end

      _out, err = capture_io do
        with_replaced_singleton_method(Hive::TaskMeta, :read_for_update!, delete_after_read) do
          assert_nil Hive::Stages::Plan.adopt_plan_dependency!(
            task, Marker.new(:complete), observation: observation
          )
        end
      end

      assert boundary_reached, "metadata-read boundary must be exercised"
      refute File.exist?(dir)
      assert_includes err, "stale task"
    ensure
      observation&.close
      FileUtils.mkdir_p(dir) if dir && !File.exist?(dir)
    end
  end

  def test_dependency_adoption_does_not_mutate_a_same_path_replacement
    with_planned_task(plan_doc("rails-task")) do |task, dir|
      observation = Hive::TaskMeta.observe(dir)
      copied_meta = File.binread(Hive::TaskMeta.path(dir))
      copied_plan = File.binread(File.join(dir, "plan.md"))
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      File.binwrite(Hive::TaskMeta.path(dir), copied_meta)
      File.binwrite(File.join(dir, "plan.md"), copied_plan)
      File.write(File.join(dir, "replacement.txt"), "untouched\n")

      _out, err = capture_io do
        assert_nil Hive::Stages::Plan.adopt_plan_dependency!(
          task, Marker.new(:complete), observation: observation
        )
      end

      assert_nil Hive::TaskMeta.read(dir)[:depends_on]
      assert_equal "untouched\n", File.read(File.join(dir, "replacement.txt"))
      assert_includes err, "stale task"
    ensure
      observation&.close
    end
  end

  def test_unexpected_dependency_adoption_failure_is_not_swallowed
    with_planned_task(plan_doc("rails-task")) do |task, _dir|
      failing = ->(*, **) { raise RuntimeError, "programmer error" }

      with_replaced_singleton_method(Hive::TaskMeta, :rewrite, failing) do
        error = assert_raises(RuntimeError) do
          Hive::Stages::Plan.adopt_plan_dependency!(task, Marker.new(:complete))
        end
        assert_equal "programmer error", error.message
      end
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

  def render_plan_prompt(carried: "", source: nil, tag: Hive::Stages::Base.user_supplied_tag)
    Hive::Stages::Base.render(
      "plan_prompt.md.erb",
      Hive::Stages::Base::TemplateBindings.new(
        project_name: "demo", task_folder: "/tmp/task", brainstorm_text: "idea",
        carried_decisions_text: carried, source_checkout: source,
        user_supplied_tag: tag, skill_invocation: "/plan"
      )
    )
  end

  def test_plan_prompt_wraps_carried_decisions_as_user_supplied_data
    tag = Hive::Stages::Base.user_supplied_tag
    with_decisions = render_plan_prompt(carried: "- Operator exit (gated_auto, high risk; prf-a)", tag: tag)
    assert_includes with_decisions, "<#{tag} content_type=\"plan_review_decisions\">"
    assert_includes with_decisions, "- Operator exit (gated_auto, high risk; prf-a)"
    refute_includes render_plan_prompt, "plan_review_decisions"
  end

  def test_plan_prompt_points_the_planner_at_the_source_checkout
    assert_includes render_plan_prompt(source: "/tmp/base-checkout"), "Source checkout: /tmp/base-checkout"
    refute_includes render_plan_prompt, "Source checkout:"
  end

  def with_cleared_plan_state(marker:, allowed:, freshness:, load_error: nil)
    record = Object.new
    record.define_singleton_method(:execution_allowed?) { allowed }
    projection = Struct.new(:record).new(record)
    load = load_error ? ->(task_folder:) { raise load_error } : ->(task_folder:) { projection }
    Dir.mktmpdir do |folder|
      Hive::TaskMeta.write(folder, id: 7, slug: "task", display_name: nil)
      File.write(File.join(folder, "plan.md"), "# Plan\n<!-- COMPLETE -->\n")
      with_replaced_singleton_method(Hive::Markers, :current, ->(*) { Struct.new(:name).new(marker) }) do
        with_replaced_singleton_method(Hive::PlanReview::Projection, :load, load) do
          with_replaced_singleton_method(Hive::PlanReview::TransitionGuard, :freshness,
                                         ->(**) { { "status" => freshness, "reason" => nil } }) do
            yield Struct.new(:folder, :slug, :state_file, keyword_init: true)
              .new(folder: folder, slug: "task", state_file: File.join(folder, "plan.md"))
          end
        end
      end
    end
  end

  # Re-running a cleared, current plan must not respawn the planner: that edited
  # plan.md, staled the cleared review, and restarted the review cycle.
  def test_run_leaves_a_cleared_current_plan_untouched
    with_cleared_plan_state(marker: :complete, allowed: true, freshness: "current") do |task|
      planned = false
      with_replaced_singleton_method(Hive::Stages::Plan, :with_source_checkout, ->(*) { planned = true }) do
        result = Hive::Stages::Plan.run!(task, {})
        assert_equal :complete, result.fetch(:status)
        assert_equal "complete", result.fetch(:commit)
      end
      refute planned, "a cleared plan must not respawn the planner"
    end
  end

  def test_run_replans_when_the_cleared_review_is_not_current_or_readable
    [
      { marker: :complete, allowed: true, freshness: "stale" },
      { marker: :complete, allowed: false, freshness: "current" },
      { marker: :waiting, allowed: true, freshness: "current" },
      { marker: :complete, allowed: true, freshness: "current", load_error: Hive::PlanReview::InvalidRecord.new("none") }
    ].each do |state|
      with_cleared_plan_state(**state) do |task|
        refute Hive::Stages::Plan.cleared_plan_ready?(task, {}), state.inspect
      end
    end
  end
end
