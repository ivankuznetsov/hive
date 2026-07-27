require "test_helper"
require "hive/archive_filter"

class ArchiveFilterTest < Minitest::Test
  FakeTask = Data.define(:folder, :workflow, :completed_at)
  FakeBackfiller = Data.define(:values, :calls) do
    def call(tasks)
      calls << tasks.map(&:folder)
      tasks.to_h { |task| [ task.folder, values[task.folder] ] }
    end
  end

  def test_default_policy_keeps_exact_boundary_and_hides_one_second_later
    now = Time.utc(2026, 6, 4, 12, 0, 0)
    workflow = workflow_with_retention(3)

    refute Hive::ArchiveFilter.hide?(
      action: "archived", retention: workflow.archive_visibility_retention_days,
      completed_at: now - (3 * 86_400),
      now: now
    )
    assert Hive::ArchiveFilter.hide?(
      action: "archived", retention: workflow.archive_visibility_retention_days,
      completed_at: now - (3 * 86_400) - 1,
      now: now
    )
  end

  def test_custom_and_never_policies
    now = Time.utc(2026, 6, 4, 12, 0, 0)

    refute Hive::ArchiveFilter.hide?(
      action: "archived", retention: 7, completed_at: now - (7 * 86_400), now: now
    )
    assert Hive::ArchiveFilter.hide?(
      action: "archived", retention: 7, completed_at: now - (7 * 86_400) - 1, now: now
    )
    refute Hive::ArchiveFilter.hide?(
      action: "archived", retention: :never, completed_at: now - (999 * 86_400), now: now
    )
  end

  def test_non_archived_missing_and_future_clocks_fail_open
    now = Time.utc(2026, 6, 4, 12, 0, 0)

    refute Hive::ArchiveFilter.hide?(
      action: "error", retention: 3, completed_at: now - (99 * 86_400), now: now
    )
    refute Hive::ArchiveFilter.hide?(
      action: "archived", retention: 3, completed_at: nil, now: now
    )
    refute Hive::ArchiveFilter.hide?(
      action: "archived", retention: 3, completed_at: now + 86_400, now: now
    )
  end

  def test_projection_uses_action_membership_and_backfills_even_under_never
    now = Time.utc(2026, 6, 4, 12, 0, 0)
    archived = row("/archived", action: "archived", retention: :never)
    same_directory_active = row("/active", action: "ready_to_run", retention: 3)
    calls = []
    backfiller = FakeBackfiller.new(values: { "/archived" => now - (20 * 86_400) }, calls: calls)

    projection = Hive::ArchiveFilter.project(
      [ archived, same_directory_active ], now: now, backfiller: backfiller
    )

    assert_equal [ archived, same_directory_active ], projection.ordinary_rows
    assert_equal [ archived ], projection.archive_rows
    assert_equal 0, projection.hidden_count
    assert_equal [ [ "/archived" ] ], calls
  end

  def test_projection_derives_visible_set_and_hidden_count_from_same_rows
    now = Time.utc(2026, 6, 4, 12, 0, 0)
    hidden = row("/hidden", action: "archived", retention: 3)
    recent = row("/recent", action: "archived", retention: 3)
    active = row("/active", action: "ready_to_run", retention: 3)
    backfiller = FakeBackfiller.new(
      values: {
        "/hidden" => now - (3 * 86_400) - 1,
        "/recent" => now - (3 * 86_400)
      },
      calls: []
    )

    projection = Hive::ArchiveFilter.project(
      [ hidden, recent, active ], now: now, backfiller: backfiller
    )

    assert_equal [ recent, active ], projection.ordinary_rows
    assert_equal [ hidden, recent ], projection.archive_rows
    assert_equal [ hidden ], projection.hidden_rows
    assert_equal 1, projection.hidden_count
  end

  def test_archive_membership_survives_presentation_action_errors
    now = Time.utc(2026, 6, 4, 12, 0, 0)
    archived = row(
      "/archived", action: Hive::Schemas::TaskActionKind::ADMISSION_ERROR,
      retention: 3, completed_at: now - (10 * 86_400)
    ).merge(archive_member: true)

    projection = Hive::ArchiveFilter.project([ archived ], now: now)

    assert_equal [ archived ], projection.archive_rows
    assert_equal [ archived ], projection.hidden_rows
    assert_empty projection.ordinary_rows
  end

  private

  def workflow_with_retention(retention)
    Hive::Workflow.new(
      id: :test,
      stages: [
        Hive::Workflow::Stage.new(
          name: "done", index: 1, state_file: "task.md", kind: :inert,
          deliverable: nil, advance_verb: nil, agent: nil, council: nil
        )
      ],
      archive_visibility_retention_days: retention
    )
  end

  def row(folder, action:, retention:, completed_at: nil)
    {
      stage: "2-done",
      action_key: action,
      task: FakeTask.new(
        folder: folder,
        workflow: workflow_with_retention(retention),
        completed_at: completed_at
      )
    }
  end
end
