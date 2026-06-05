require "hive/stages"

module Hive
  module ArchiveFilter
    ARCHIVE_STAGE_DIR = Hive::Stages::DIRS.last
    # Locked product decision: hide archived tasks after 3 days in
    # day-to-day surfaces. This is intentionally not configurable.
    HIDE_AFTER_SECONDS = 3 * 24 * 60 * 60

    module_function

    def archived?(stage_dir)
      stage_dir == ARCHIVE_STAGE_DIR
    end

    # Timestamp contract: `mtime` (the row's own mtime) takes precedence
    # over `folder_mtime`; the first non-nil of the two is the archive
    # time. When BOTH are nil we cannot know how long the row has been
    # archived, so we deliberately never hide it (fail-open) rather than
    # raise — an undated archived row stays visible.
    def hide?(stage:, mtime: nil, folder_mtime: nil, now: Time.now)
      return false unless archived?(stage)
      archived_at = mtime || folder_mtime
      return false unless archived_at

      (now - archived_at) > HIDE_AFTER_SECONDS
    end
  end
end
