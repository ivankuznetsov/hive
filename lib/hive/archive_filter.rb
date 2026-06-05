require "hive/stages"

module Hive
  module ArchiveFilter
    ARCHIVE_STAGE_DIR = Hive::Stages::DIRS.last
    # Locked product decision: hide clean archived tasks after 3 days in
    # day-to-day surfaces. This is intentionally not configurable.
    HIDE_AFTER_SECONDS = 3 * 24 * 60 * 60
    # Only resolved marker states may be hidden. Review this allowlist when
    # adding to Hive::Markers::TERMINAL_MARKER_NAMES or introducing new marker
    # names: anything not listed here remains visible by default.
    RESOLVED_MARKER_NAMES = %i[complete none].freeze

    module_function

    def archived?(stage_dir)
      stage_dir == ARCHIVE_STAGE_DIR
    end

    def hide?(stage:, marker_name:, folder_mtime:, now: Time.now)
      return false unless archived?(stage)
      return false unless RESOLVED_MARKER_NAMES.include?(marker_name.to_s.to_sym)
      return false unless folder_mtime

      (now - folder_mtime) > HIDE_AFTER_SECONDS
    end
  end
end
