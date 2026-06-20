require "hive/workflows/registry"

module Hive
  # Public source of truth for the CODING workflow verbs (brainstorm, plan,
  # develop, open-pr, review, artifacts, finalize, archive), derived from
  # the default (coding) workflow descriptor. Each verb advances a task from
  # one stage to the next; the derived `VERBS` map drives the coding paths:
  # `Hive::Commands::StageAction` consumes it to dispatch the move and
  # `Hive::TaskAction` uses it to label the "ready to <verb>" status bucket
  # per coding stage. The generic `Hive::Commands::Approve` next-action path
  # no longer reads `VERBS` — it derives the verb per-task via
  # `task.workflow.advance_verb_for` (U6) so non-coding descriptors resolve
  # their own verbs.
  #
  # Adding or removing a coding verb follows the default workflow descriptor.
  module Workflows
    # Descriptor id of the built-in coding workflow. The "nil/blank/coding
    # ⟹ coding" defaulting rule gates every coding-only daemon/bot branch,
    # so it lives here once instead of being re-spelled at each consumer.
    CODING_ID = :coding

    # Optional `interactive: true` flag marks verbs that need the user's
    # tty during execution (stdin prompts, interactive `gh pr create`,
    # claude tool-permission asks). The TUI's `BubbleModel#dispatch_command`
    # routes interactive verbs through `Subprocess.takeover_command`
    # (foreground takeover with alt-screen toggle) instead of the
    # default `Subprocess.dispatch_background` (no stdin, headless
    # log capture).
    #
    # Default is non-interactive (omitting the key). No verb is flagged
    # interactive in v1 because every workflow agent currently runs
    # claude with captured stdio and `gh pr create` has been working
    # non-interactively for `hive open-pr`. The flag is present so a future
    # verb that DOES need stdin (e.g., a manual review prompt) can
    # opt in with one line — without re-introducing foreground
    # takeover for everything.
    stages = Hive::Workflows::Registry.default.stages
    # each_cons(2) walks adjacent [source, target] pairs so a verb's `source`
    # is always the stage that PRECEDES its target — expressed directly instead
    # of via `fetch(index - 1)`, whose negative index at index 0 would wrap a
    # first-stage advance_verb to the terminal stage. The descriptor's first
    # stage never carries an advance_verb (enforced by Workflow's
    # construction-time validation), so starting the pairing at the second
    # stage drops no verb.
    VERBS = stages.each_cons(2).each_with_object({}) do |(source, target), verbs|
      advance_verb = target.advance_verb
      next unless advance_verb

      entry = {
        source: source.dir,
        target: target.dir
      }
      entry[:force_source] = true if advance_verb.force_source
      entry[:interactive] = true if advance_verb.interactive
      verbs[advance_verb.name] = entry
    end.freeze

    # Reverse lookup by source: verb that advances OUT of stage_dir.
    # nil for `9-done` (no further verb).
    VERB_BY_SOURCE = VERBS.each_with_object({}) { |(verb, cfg), h| h[cfg[:source]] = verb }.freeze

    # Reverse lookup by target: verb whose target IS stage_dir. Same
    # name as the stage's "ready to run" agent — after arriving at
    # `3-plan`, `hive plan <slug> --from 3-plan` runs the plan agent.
    # nil for `1-inbox` (no verb arrives there; tasks are created via
    # `hive new`).
    VERB_BY_TARGET = VERBS.each_with_object({}) { |(verb, cfg), h| h[cfg[:target]] = verb }.freeze

    module_function

    def for_verb(verb)
      VERBS.fetch(verb)
    end

    def verb_advancing_from(stage_dir)
      VERB_BY_SOURCE[stage_dir]
    end

    # Stage directory that follows stage_dir in the pipeline, or nil at the
    # terminal stage. Use this instead of hardcoding `"7-artifacts"` / # not-a-stage-ref: documentation example
    # `"8-finalize"` etc. so a future renumber doesn't strand call sites. # not-a-stage-ref: documentation example
    def next_dir_after(stage_dir)
      verb = VERB_BY_SOURCE[stage_dir]
      verb && VERBS.fetch(verb).fetch(:target)
    end

    # Returns true when the verb is flagged `interactive: true` —
    # used by the TUI to route the dispatch through foreground
    # takeover instead of background spawn. `nil`/missing-verb
    # returns false (safe default: assume headless).
    def interactive?(verb)
      cfg = VERBS[verb.to_s]
      return false if cfg.nil?

      cfg[:interactive] == true
    end

    # The verb whose target is stage_dir — used as the "what to do
    # next" command after a successful advance. Calling that verb on
    # the freshly-arrived task hits StageAction's at-target branch and
    # runs the stage's agent.
    def verb_arriving_at(stage_dir)
      VERB_BY_TARGET[stage_dir]
    end

    def workflow_verb?(verb)
      VERBS.key?(verb)
    end

    # True when a workflow *value* (a descriptor id as Symbol or String, or
    # nil/blank from older status payloads / test doubles) denotes the
    # coding workflow. Single source of truth for the "nil/blank/coding ⟹
    # coding" rule that several daemon/bot consumers used to re-spell.
    def coding_id?(value)
      return true if value.nil?

      string = value.to_s
      string.empty? || string == CODING_ID.to_s
    end

    # True when a status *row* resolves to the coding workflow. A row that
    # does not respond to `#workflow` (older payloads / test doubles)
    # defaults to coding so legacy consumers keep the coding behavior.
    #
    # The workflow selector travels in three row shapes across the codebase,
    # and new reads should route through these two predicates rather than
    # reaching for one accessor and risking a silent nil:
    #   - status builder Hash  → `row[:workflow]`  (use coding_id?)
    #   - status JSON payload  → `task["workflow"]` (use coding_id?)
    #   - StatusWatcher::Row   → `row.workflow`    (use coding_row?)
    # coding_row? is the row-shaped front door (it `respond_to?`-guards the
    # accessor); coding_id? is the value-shaped one for the Hash/JSON forms.
    def coding_row?(row)
      return true unless row.respond_to?(:workflow)

      coding_id?(row.workflow)
    end

    # Memoized: the registry is frozen at load, so the union of every
    # workflow's stage dirs/names never changes after boot. Recomputing a
    # frozen array on every call (status snapshots, drop, resolver) is pure
    # waste. Not an eager constant — that would re-enter the require cycle
    # (workflows.rb ⇆ registry.rb) before the registry is populated.
    def all_stage_dirs
      @all_stage_dirs ||= Registry.all.flat_map(&:stage_dirs).uniq.freeze
    end

    def all_stage_names
      @all_stage_names ||= Registry.all.flat_map(&:stage_names).uniq.freeze
    end

    # Resolve a user-provided stage ref (a full N-name dir or a bare short
    # name) against EVERY registered workflow (not just coding) and return the
    # single canonical `N-name` dir it maps to. Returns nil for a blank ref; raises
    # `Hive::InvalidTaskPath` on an ambiguous ref (matches >1 workflow) or an
    # unknown one. Shared by `Hive::TaskResolver` and `Hive::Commands::Drop`
    # so a generic `--from`/`--stage <stage>` is accepted identically and the
    # two error strings stay in lockstep instead of drifting apart.
    def resolve_stage_ref_across_workflows(stage_ref)
      return nil if stage_ref.nil? || stage_ref.to_s.strip.empty?

      raw = stage_ref.to_s.strip
      matches = Registry.all.filter_map { |workflow| workflow.resolve_stage_ref(raw) }.uniq
      return matches.first if matches.one?

      if matches.size > 1
        raise Hive::InvalidTaskPath, "ambiguous stage '#{stage_ref}'; matches: #{matches.join(', ')}"
      end

      raise Hive::InvalidTaskPath,
            "unknown stage '#{stage_ref}'; valid: #{all_stage_dirs.join(', ')} " \
            "or short names #{all_stage_names.join(', ')}"
    end
  end
end
