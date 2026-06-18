require "hive/stages"

module Hive
  module Dependencies
    # `unresolved` is NOT a stored field: it is derived so the three-field
    # tuple can never contradict itself. A blocked row with no identified
    # prerequisite (missing dependency or self-reference) is unresolved; a
    # blocked row that names a prerequisite slug is a real below-gate wait.
    # `resolve` guarantees the correlation `unresolved? ⟺ (blocked &&
    # blocked_by.nil?)` by construction (see the resolved⟹slug guard below).
    Result = Data.define(:blocked_by, :dependency_stage, :blocked) do
      def unresolved?
        blocked && blocked_by.nil?
      end
    end

    module_function

    def resolve(depends_on:, tasks:, threshold_stage:, task: nil)
      dependency = normalize_depends_on(depends_on)
      return Result.new(blocked_by: nil, dependency_stage: nil, blocked: false) unless dependency

      prerequisite = find_task(dependency, tasks)
      if prerequisite.nil? || same_task?(prerequisite, task)
        return Result.new(blocked_by: nil, dependency_stage: nil, blocked: true)
      end

      # Resolved ⟹ slug present. Every snapshot builder guarantees a slug,
      # so a resolved prerequisite without one is a corrupt input, not a
      # missing dependency — raise rather than emit a tuple that would
      # render as "(unresolved)". Callers on the never-fail status surface
      # isolate this per row, not per project: apply_dependency_result
      # rescues each row independently, so one corrupt prerequisite blanks
      # only its own dependent's gate, not the whole project's.
      slug = task_slug(prerequisite)
      raise ArgumentError, "resolved prerequisite #{dependency.inspect} has no slug" unless slug

      stage = stage_name_for(prerequisite)
      blocked = stage_index_for(prerequisite) < threshold_index(threshold_stage)
      Result.new(blocked_by: slug, dependency_stage: stage, blocked: blocked)
    end

    # Single source of truth for the "⏸ blocked by …" indicator rendered by
    # both Commands::Status (text mode) and Tui::Views::TasksPane. The
    # unresolved-vs-resolved discriminator is `blocked_by` presence —
    # `resolve`'s resolved⟹slug guard makes a resolved prerequisite always
    # carry its slug and an unresolved one (missing / self-reference) always
    # nil — so the two renderers can never diverge on the predicate.
    def blocked_label(depends_on:, blocked_by:, dependency_stage:)
      if blocked_by.to_s.strip.empty?
        "⏸ blocked by #{depends_on} (unresolved)"
      else
        "⏸ blocked by #{blocked_by} (#{dependency_stage})"
      end
    end

    def base_branch_for(depends_on:, tasks:, default_branch:, task: nil)
      dependency = normalize_depends_on(depends_on)
      return default_branch unless dependency

      prerequisite = find_task(dependency, tasks)
      return default_branch if prerequisite.nil? || same_task?(prerequisite, task)

      task_slug(prerequisite) || default_branch
    end

    def find_task(depends_on, tasks)
      tasks.find { |candidate| task_slug(candidate) == depends_on } ||
        (numeric?(depends_on) ? tasks.find { |candidate| task_id(candidate) == Integer(depends_on) } : nil)
    end

    def normalize_depends_on(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def numeric?(value)
      value.to_s.match?(/\A\d+\z/)
    end

    def same_task?(left, right)
      return false unless right

      left_slug = task_slug(left)
      right_slug = task_slug(right)
      return true if left_slug && right_slug && left_slug == right_slug

      left_id = task_id(left)
      right_id = task_id(right)
      left_id && right_id && left_id == right_id
    end

    def task_slug(task)
      field(task, :slug)
    end

    def task_id(task)
      raw = field(task, :id)
      return raw if raw.is_a?(Integer)
      return nil if raw.nil? || raw.to_s.strip.empty?

      Integer(raw)
    rescue ArgumentError, TypeError
      # A corrupt prerequisite id (non-numeric string in meta.yml) makes a
      # numeric `depends_on` silently mis-resolve. Leave a breadcrumb so the
      # "typo in depends_on" case is distinguishable from "prereq id is
      # garbage" when debugging an unexpected unresolved gate.
      warn "[hive] dependencies: prerequisite id #{raw.inspect} is not an integer; " \
           "ignoring it for numeric depends_on matching"
      nil
    end

    def stage_index_for(task)
      raw = field(task, :stage_index)
      return raw if raw.is_a?(Integer)
      return Integer(raw) if raw

      stage = field(task, :stage)
      resolved = Hive::Stages.resolve(stage.to_s)
      return Hive::Stages::DIRS.index(resolved) + 1 if resolved

      raise ArgumentError, "dependency task #{task_slug(task).inspect} has no valid stage"
    end

    def stage_name_for(task)
      stage = field(task, :stage)
      resolved = Hive::Stages.resolve(stage.to_s)
      return resolved if resolved

      Hive::Stages::DIRS.fetch(stage_index_for(task) - 1)
    end

    def threshold_index(threshold_stage)
      resolved = Hive::Stages.resolve(threshold_stage.to_s)
      raise ArgumentError, "unknown dependency gate stage #{threshold_stage.inspect}" unless resolved

      Hive::Stages::DIRS.index(resolved) + 1
    end

    # Read `key` (a symbol) from `task`, which is either a Hash (symbol- or
    # string-keyed) or an object exposing `key` as a reader. EVERY production
    # caller passes a SYMBOL-keyed Hash: Status#apply_dependency_result and
    # DependencySnapshot#stacked_base both project their rows/tasks into
    # symbol-keyed Hashes before calling in (the snapshot deliberately does
    # not duck-type other inputs). The string-key arm and the reader arm are
    # test-ergonomics / forward-compat only — no production path passes a
    # string-keyed Hash or a reader-exposing object (e.g. a `Hive::Task`)
    # today. Returns nil only when the key is genuinely absent from a
    # recognized shape; warns (and returns nil) when `task` is neither
    # hash-like nor a reader-exposing object, so a wrong-shaped caller leaves
    # a breadcrumb instead of silently resolving every field to "missing".
    def field(task, key)
      if task.respond_to?(:key?)
        return task[key] if task.key?(key)
        return task[key.to_s] if task.key?(key.to_s)

        nil
      elsif task.respond_to?(key)
        task.public_send(key)
      else
        warn "[hive] dependencies: unrecognized task shape #{task.class} " \
             "(expected Hash or object responding to #{key}); treating #{key} as missing"
        nil
      end
    end
  end
end
