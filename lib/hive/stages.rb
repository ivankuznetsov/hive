module Hive
  # Single source of truth for the stage list. Consumers (GitOps init, Status
  # ordering, Run#next_stage_dir, Approve resolution) all read from here so
  # adding a 7th stage or renaming an existing one is a one-file change.
  module Stages
    DIRS = %w[1-inbox 2-brainstorm 3-plan 4-execute 5-pr 6-done].freeze
    NAMES = DIRS.map { |d| d.split("-", 2).last }.freeze
    SHORT_TO_FULL = DIRS.each_with_object({}) { |d, h| h[d.split("-", 2).last] = d }.freeze

    module_function

    # Directory for the stage *after* the one at idx (1-based). Returns nil at
    # the final stage. DIRS[idx] works because stage_index is 1-based and the
    # array is 0-based: idx=1 ("1-inbox") → DIRS[1] = "2-brainstorm".
    def next_dir(idx)
      DIRS[idx]
    end

    # Resolve a user-provided stage string ("3-plan" or "plan") to a canonical
    # DIRS entry, or nil if neither shape matches.
    def resolve(name)
      return name if DIRS.include?(name)

      SHORT_TO_FULL[name]
    end

    # ["3-plan"] → [3, "plan"]; nil if malformed.
    def parse(dir)
      idx, name = dir.split("-", 2)
      return nil unless name && idx.match?(/\A\d+\z/)

      [ idx.to_i, name ]
    end
  end
end
