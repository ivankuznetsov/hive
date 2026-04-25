module Hive
  # Single source of truth for the stage list. Consumers (GitOps init, Status
  # ordering, Run#next_stage_dir, Approve resolution) all read from here so
  # adding a 7th stage or renaming an existing one is a one-file change.
  module Stages
    DIRS = %w[1-inbox 2-brainstorm 3-plan 4-execute 6-pr 7-done].freeze
    NAMES = DIRS.map { |d| d.split("-", 2).last }.freeze
    SHORT_TO_FULL = DIRS.each_with_object({}) { |d, h| h[d.split("-", 2).last] = d }.freeze

    module_function

    # Directory for the stage *after* the one whose numeric prefix is `idx`.
    # Returns nil when `idx` is past the final stage's prefix or when no
    # stage with prefix `idx` exists (the renumber to 1/2/3/4/6/7 means
    # stage_index 5 is unused until 5-review lands; callers querying it
    # get nil cleanly). Out-of-range argument types raise so off-by-one
    # bugs surface at the call site rather than silently returning nil.
    def next_dir(idx)
      raise ArgumentError, "stage index out of range: #{idx.inspect}" unless idx.is_a?(Integer) && idx >= 1

      current_array_idx = DIRS.index { |d| d.start_with?("#{idx}-") }
      return nil unless current_array_idx

      DIRS[current_array_idx + 1]
    end

    # Resolve a user-provided stage string ("3-plan" or "plan") to a
    # canonical DIRS entry, or nil if neither shape matches.
    def resolve(name)
      return name if DIRS.include?(name)

      SHORT_TO_FULL[name]
    end

    # Validate `dir` is a known stage directory and return [index, name].
    # Returns nil only for inputs that aren't known stages — callers that
    # need fail-loud semantics should raise on nil. (`"99-foo"` returns nil
    # rather than `[99, "foo"]` so a hand-constructed stage string can't
    # silently slip past validation.)
    def parse(dir)
      return nil unless DIRS.include?(dir)

      idx, name = dir.split("-", 2)
      [ idx.to_i, name ]
    end
  end
end
