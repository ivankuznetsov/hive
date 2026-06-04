module Hive
  # Single source of truth for the stage list. Consumers (GitOps init, Status
  # ordering, Run#next_stage_dir, Approve resolution) all read from here so
  # adding or renaming a stage is a one-file change.
  module Stages
    DIRS = %w[
      1-inbox
      2-brainstorm
      3-plan
      4-execute
      5-open-pr
      6-review
      7-artifacts
      8-finalize
      9-done
    ].freeze
    NAMES = DIRS.map { |d| d.split("-", 2).last }.freeze
    SHORT_TO_FULL = DIRS.each_with_object({}) { |d, h| h[d.split("-", 2).last] = d }.freeze

    # Slug shape for task-folder names (see Task::PATH_RE / Migrate::SLUG_RE).
    # Single source of truth so the legacy-stage detector in
    # `Hive::Commands::Status` and the `Hive::Commands::Migrate` walker stay
    # in lockstep — both must treat the same set of entries as task folders.
    SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/

    module_function

    # True iff `name` is a task-folder slug (per `SLUG_RE`). Used by Status
    # to count only task subfolders inside a legacy stage dir (skipping
    # `.gitkeep`, `logs/`, `.DS_Store`, etc.) and by Migrate to decide
    # which entries it is allowed to mv.
    def task_slug?(name)
      SLUG_RE.match?(name.to_s)
    end

    # Directory for the stage *after* the one whose numeric prefix is `idx`.
    # Returns nil when `idx` is past the final stage's prefix or when no
    # stage with prefix `idx` exists. Out-of-range argument types raise so off-by-one
    # bugs surface at the call site rather than silently returning nil.
    def next_dir(idx)
      raise ArgumentError, "stage index out of range: #{idx.inspect}" unless idx.is_a?(Integer) && idx >= 1

      current_array_idx = DIRS.index { |d| d.start_with?("#{idx}-") }
      return nil unless current_array_idx

      DIRS[current_array_idx + 1]
    end

    # Directory for the stage *before* the one whose numeric prefix is `idx`.
    # Returns nil when `idx` is the first stage or when no stage with prefix
    # `idx` exists. Used by the web reject action to send a task back to its
    # immediately-prior gate rather than a hardcoded stage. Out-of-range
    # argument types raise so off-by-one bugs surface at the call site.
    def prev_dir(idx)
      raise ArgumentError, "stage index out of range: #{idx.inspect}" unless idx.is_a?(Integer) && idx >= 1

      current_array_idx = DIRS.index { |d| d.start_with?("#{idx}-") }
      return nil unless current_array_idx && current_array_idx.positive?

      DIRS[current_array_idx - 1]
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
