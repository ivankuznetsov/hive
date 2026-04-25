module Hive
  # Single source of truth for the stage list. Consumers (GitOps init, Status
  # ordering, Run#next_stage_dir, Approve resolution) all read from here so
  # adding a 7th stage or renaming an existing one is a one-file change.
  module Stages
    DIRS = %w[1-inbox 2-brainstorm 3-plan 4-execute 5-pr 6-done].freeze
    NAMES = DIRS.map { |d| d.split("-", 2).last }.freeze
    SHORT_TO_FULL = DIRS.each_with_object({}) { |d, h| h[d.split("-", 2).last] = d }.freeze

    module_function

    # Directory for the stage *after* the one at the given 1-based index.
    # Returns nil for indices at or past the final stage. Out-of-range
    # arguments raise so an off-by-one shows up at the call site rather
    # than silently returning nil and being indistinguishable from "final".
    def next_dir(idx)
      raise ArgumentError, "stage index out of range: #{idx.inspect}" unless idx.is_a?(Integer) && idx >= 1

      DIRS[idx]
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
