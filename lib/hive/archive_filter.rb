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

    # `folder_mtime:` is a required keyword so a caller cannot *omit* the
    # timestamp argument entirely and get a quiet `false`; `mtime:` is the
    # optional row-level override that takes precedence when present. Note
    # this only guards the argument-omission spelling: an explicit
    # `folder_mtime: nil` (which both production callers can pass) still
    # falls through to the quiet-`false` branch below. We deliberately do
    # NOT raise on an all-nil timestamp — callers cannot guarantee a
    # non-nil mtime, so a missing timestamp must degrade to "don't hide".
    def hide?(stage:, folder_mtime:, mtime: nil, now: Time.now)
      return false unless archived?(stage)
      archived_at = mtime || folder_mtime
      return false unless archived_at

      (now - archived_at) > HIDE_AFTER_SECONDS
    end
  end
end
