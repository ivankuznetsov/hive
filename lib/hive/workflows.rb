require "hive/workflows/registry"

module Hive
  # Public source of truth for the workflow verbs (brainstorm, plan,
  # develop, open-pr, review, artifacts, finalize, archive), derived from
  # the default workflow descriptor. Each verb advances a task from one
  # stage to the next; consumers all read from the derived `VERBS` map:
  # `Hive::Commands::StageAction` consumes it to dispatch the move,
  # `Hive::TaskAction` uses it to label the "ready to <verb>" status
  # bucket per stage, and `Hive::Commands::Approve` uses it to derive
  # the next-action command after a successful move.
  #
  # Adding or removing a verb follows the default workflow descriptor.
  module Workflows
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
    VERBS = stages.each_with_index.each_with_object({}) do |(stage, index), verbs|
      advance_verb = stage.advance_verb
      next unless advance_verb

      entry = {
        source: stages.fetch(index - 1).dir,
        target: stage.dir
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

    def all_stage_dirs
      Registry.all.flat_map(&:stage_dirs).uniq.freeze
    end

    def all_stage_names
      Registry.all.flat_map(&:stage_names).uniq.freeze
    end
  end
end
