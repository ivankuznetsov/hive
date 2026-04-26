module Hive
  # Single source of truth for the six workflow verbs (brainstorm, plan,
  # develop, review, pr, archive). Each verb advances a task from one
  # stage to the next; `Hive::Commands::StageAction` consumes this map
  # directly, `Hive::TaskAction` uses it to label the "ready to <verb>"
  # status bucket per stage, and `Hive::Commands::Approve` /
  # `FindingToggle` use it to derive the next-action command after a
  # successful move.
  #
  # Adding or removing a verb is a one-file change here.
  module Workflows
    VERBS = {
      "brainstorm" => { source: "1-inbox", target: "2-brainstorm", force_source: true },
      "plan"       => { source: "2-brainstorm", target: "3-plan" },
      "develop"    => { source: "3-plan", target: "4-execute" },
      "review"     => { source: "4-execute", target: "5-review" },
      "pr"         => { source: "5-review", target: "6-pr" },
      "archive"    => { source: "6-pr", target: "7-done" }
    }.freeze

    # Reverse lookup by source: verb that advances OUT of stage_dir.
    # nil for `6-done` (no further verb).
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
  end
end
