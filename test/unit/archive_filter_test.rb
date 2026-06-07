require "test_helper"
require "hive/archive_filter"

class ArchiveFilterTest < Minitest::Test
  def test_archive_stage_dir_tracks_final_stage
    assert_equal Hive::Stages::DIRS.last, Hive::ArchiveFilter::ARCHIVE_STAGE_DIR
    assert Hive::ArchiveFilter.archived?(Hive::Stages::DIRS.last)
  end

  def test_hides_archived_rows_older_than_threshold
    now = Time.utc(2026, 6, 4, 12, 0, 0)

    assert Hive::ArchiveFilter.hide?(
      stage: Hive::Stages::DIRS.last,
      folder_mtime: now - (5 * 86_400),
      now: now
    )
  end

  def test_keeps_archived_rows_under_or_at_threshold
    now = Time.utc(2026, 6, 4, 12, 0, 0)

    refute Hive::ArchiveFilter.hide?(
      stage: Hive::Stages::DIRS.last,
      folder_mtime: now - 86_400,
      now: now
    )
    refute Hive::ArchiveFilter.hide?(
      stage: Hive::Stages::DIRS.last,
      folder_mtime: now - Hive::ArchiveFilter::HIDE_AFTER_SECONDS,
      now: now
    )
  end

  def test_hides_archived_rows_regardless_of_marker_state
    now = Time.utc(2026, 6, 4, 12, 0, 0)

    assert Hive::ArchiveFilter.hide?(
      stage: Hive::Stages::DIRS.last,
      folder_mtime: now - (10 * 86_400),
      now: now
    ), "archived rows past the threshold must be hidden by age alone"
  end

  def test_row_mtime_takes_precedence_over_folder_mtime
    now = Time.utc(2026, 6, 4, 12, 0, 0)

    assert Hive::ArchiveFilter.hide?(
      stage: Hive::Stages::DIRS.last,
      mtime: now - (5 * 86_400),
      folder_mtime: now - 86_400,
      now: now
    )
    refute Hive::ArchiveFilter.hide?(
      stage: Hive::Stages::DIRS.last,
      mtime: now - 86_400,
      folder_mtime: now - (5 * 86_400),
      now: now
    )
  end

  def test_never_hides_non_archived_or_unknown_mtime_rows
    now = Time.utc(2026, 6, 4, 12, 0, 0)

    refute Hive::ArchiveFilter.hide?(
      stage: "3-plan",
      folder_mtime: now - (99 * 86_400),
      now: now
    )
    refute Hive::ArchiveFilter.hide?(
      stage: Hive::Stages::DIRS.last,
      folder_mtime: nil,
      now: now
    )
  end
end
