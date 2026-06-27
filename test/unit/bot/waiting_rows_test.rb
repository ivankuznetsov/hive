require "test_helper"
require "hive/bot/waiting_rows"
require "hive/bot/status_watcher"
require "hive/commands/status"

class HiveBotWaitingRowsTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  def row(action: "needs_input", marker: "waiting", attrs: {}, slug: "slug-260625-abcd",
          stage: "2-brainstorm", workflow: "coding", diagnostic: nil, id: nil, display_name: nil,
          pr_url: nil)
    Row.new(
      project: "hive",
      project_path: "/tmp/hive",
      hive_state_path: "/tmp/hive/.hive-state",
      slug: slug,
      id: id,
      display_name: display_name,
      stage: stage,
      workflow: workflow,
      marker: marker,
      attrs: attrs,
      folder: "/tmp/#{slug}",
      state_file: "/tmp/#{slug}/task.md",
      pr_url: pr_url,
      action: action,
      action_label: "Needs input",
      suggested_command: nil,
      diagnostic: diagnostic
    )
  end

  def waiting(rows, daemon_enabled: ->(_row) { false })
    Hive::Bot::WaitingRows.select(rows, daemon_enabled: daemon_enabled)
  end

  def test_select_keeps_only_needs_input_resolution_kinds
    kept = [
      row(slug: "brainstorm-260625-aaaa", stage: "2-brainstorm", marker: "waiting"),
      row(slug: "plan-260625-bbbb", stage: "3-plan", marker: "waiting"),
      row(slug: "review-260625-cccc", stage: "6-review", marker: "review_waiting"),
      row(slug: "execute-260625-dddd", stage: "4-execute", marker: "execute_waiting"),
      row(slug: "finalize-260625-eeee", stage: "8-finalize", marker: "waiting"),
      row(slug: "generic-260625-ffff", stage: "2-gather", marker: "agent_waiting", workflow: "content")
    ]
    dropped = [
      row(slug: "recovery-260625-gggg", action: "recover_review", marker: "review_error", stage: "6-review"),
      row(slug: "approval-260625-hhhh", action: "ready_to_plan", marker: "complete", stage: "2-brainstorm"),
      row(slug: "archived-260625-iiii", action: "archived", marker: "complete", stage: "9-done"),
      row(slug: "running-260625-jjjj", action: "agent_running", marker: "agent_working", stage: "4-execute")
    ]

    selected = waiting(kept + dropped)

    assert_equal kept.map(&:slug).sort, selected.map(&:slug).sort
    assert_equal "review-260625-cccc", selected.first.slug
  end

  def test_fix_guardrail_review_row_keeps_details_callback_equal_to_push
    review = row(
      slug: "fix-guardrail-260625-abcd",
      marker: "review_waiting",
      stage: "6-review",
      attrs: { "reason" => "fix_guardrail", "pass" => "3" }
    )

    selected = waiting([ review ])
    button = Hive::Bot::WaitingRows.button_for(review)

    assert_equal [ review ], selected
    assert_equal Hive::Bot::NotificationBuilders.details_callback(review), button.fetch(:callback_data)
    assert_equal "🔍 #{Hive::Bot::NotificationBuilders.display_title(review)}", button.fetch(:text)
  end

  def test_review_triage_row_uses_accept_all_primary_callback
    review = row(slug: "triage-260625-abcd", marker: "review_waiting", stage: "6-review")

    button = Hive::Bot::WaitingRows.button_for(review)

    assert_equal "findings:accept_all:hive:triage-260625-abcd:6-review", button.fetch(:callback_data)
    assert_match(/\A✅ /, button.fetch(:text))
  end

  def test_brainstorm_and_plan_waiting_callbacks_and_daemon_plan_suppression
    brainstorm = row(slug: "brainstorm-260625-abcd", stage: "2-brainstorm", marker: "waiting")
    plan = row(slug: "plan-260625-abcd", stage: "3-plan", marker: "waiting")

    assert_equal %w[brainstorm-260625-abcd plan-260625-abcd],
                 waiting([ brainstorm, plan ]).map(&:slug)
    assert_equal "answer:hive:brainstorm-260625-abcd",
                 Hive::Bot::WaitingRows.button_for(brainstorm).fetch(:callback_data)
    assert_equal "approve_plan:hive:plan-260625-abcd:3-plan",
                 Hive::Bot::WaitingRows.button_for(plan).fetch(:callback_data)

    selected = waiting([ brainstorm, plan ], daemon_enabled: ->(candidate) { candidate.slug == plan.slug })

    assert_equal [ brainstorm.slug ], selected.map(&:slug)
  end

  def test_bad_row_resolution_is_dropped_without_aborting_the_rest
    bad = row(slug: "bad-260625-abcd")
    good = row(slug: "good-260625-abcd")
    original = Hive::Bot::RowActions.method(:resolve)
    Hive::Bot::RowActions.define_singleton_method(:resolve) do |candidate|
      raise KeyError, "boom" if candidate.slug == "bad-260625-abcd"

      original.call(candidate)
    end

    assert_equal [ good ], waiting([ bad, good ])
  ensure
    Hive::Bot::RowActions.singleton_class.send(:remove_method, :resolve)
    Hive::Bot::RowActions.define_singleton_method(:resolve, &original)
  end

  def test_review_rows_sort_before_generic_rows
    generic = row(slug: "generic-260625-abcd", stage: "2-gather", marker: "agent_waiting", workflow: "content")
    fix_guardrail = row(
      slug: "fix-guardrail-260625-abcd",
      marker: "review_waiting",
      stage: "6-review",
      attrs: { "reason" => "fix_guardrail" }
    )

    assert_equal [ fix_guardrail.slug, generic.slug ],
                 waiting([ generic, fix_guardrail ]).map(&:slug)
  end

  def test_status_source_surfaces_one_row_for_a_waiting_task
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      slug = "waiting-task-260625-abcd"
      folder = File.join(hive_state, "stages", "3-plan", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "plan.md"), "<!-- WAITING -->\n")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])
      tasks = payload.fetch("projects").first.fetch("tasks")

      assert_equal 1, tasks.count { |task| task.fetch("slug") == slug }
      assert_equal "needs_input", tasks.find { |task| task.fetch("slug") == slug }.fetch("action")
    end
  end
end
