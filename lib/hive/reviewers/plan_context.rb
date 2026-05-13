module Hive
  module Reviewers
    # Builds the "plan context" section embedded into reviewer system
    # prompts. The reviewer reads the plan inline so it can ground
    # findings against the plan's scope boundaries (Goals, Non-Goals,
    # Requirements Trace, etc.) and drop false-positive escalations
    # that flag deliberate plan-level deferrals (e.g. "feature X not
    # implemented" when the plan says X is a separate downstream task).
    #
    # Used by Hive::Reviewers::Agent#render_prompt; the rendered string
    # is passed into TemplateBindings as `plan_context_section` and
    # interpolated into the three reviewer ERB templates between the
    # "Pass:" header line and the "Behavior:" instruction block.
    #
    # When the task folder has no plan.md (or it's empty / unreadable),
    # an absent-note is returned instead so the prompt remains well-
    # formed and the reviewer is told to flag missing-plan in its
    # review output header.
    module PlanContext
      ABSENT_NOTE = <<~TEXT.freeze
        Plan context: no plan.md found in the task folder. Proceed
        without plan grounding, and note in your review output's
        header that no plan was found.
      TEXT

      module_function

      def render(task_folder)
        plan_path = File.join(task_folder.to_s, "plan.md")
        return ABSENT_NOTE unless File.exist?(plan_path)

        content = File.read(plan_path)
        return ABSENT_NOTE if content.strip.empty?

        present(content)
      rescue SystemCallError
        # Best-effort read. A permission/I-O failure must not abort
        # the reviewer spawn — fall back to the absent-note and let
        # the reviewer flag the missing-plan in its output header.
        ABSENT_NOTE
      end

      def present(plan_content)
        <<~TEXT
          Plan context (authoritative on scope):

          The plan below is the source of truth for what this task is
          meant to deliver and what is deliberately out of scope. Focus
          particularly on **Goals**, **Non-Goals** / **Scope Boundaries**,
          and **Requirements Trace** sections.

          If a candidate finding would flag a deliberate plan-level
          scope boundary (for example, "feature X not implemented" when
          the plan explicitly defers X to a separate downstream task),
          drop the finding. Your job is to catch real defects against
          the plan's intent — not to police the plan itself.

          --- BEGIN plan.md ---
          #{plan_content.rstrip}
          --- END plan.md ---
        TEXT
      end
    end
  end
end
