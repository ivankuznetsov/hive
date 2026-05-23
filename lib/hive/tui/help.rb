require "hive/workflows"

module Hive
  module Tui
    # Single source of truth for the keybinding cheatsheet shown in the
    # `?` help overlay. Each entry's `:action` is either a workflow-verb
    # symbol (cross-checked against `Hive::Workflows::VERBS` in the
    # unit test so a verb rename in `Workflows` breaks compile here) or
    # a TUI-internal symbol (filter / project_scope / help / quit /
    # back / etc.). The `:mode` field groups bindings in the help
    # overlay so the renderer can group bindings by mode.
    #
    # Adding a new workflow verb requires adding a new BINDINGS entry;
    # the cross-check test enforces consistency by asserting every
    # `:action` whose value is a workflow verb still resolves via
    # `Workflows::VERBS.fetch(action.to_s)`.
    module Help
      BINDINGS = [
        # Grid mode — workflow verbs.
        { mode: :grid, key: "b", action: :brainstorm,    description: "run hive brainstorm on highlighted task" },
        { mode: :grid, key: "p", action: :plan,          description: "run hive plan" },
        { mode: :grid, key: "d", action: :develop,       description: "run hive develop" },
        { mode: :grid, key: "r", action: :review,        description: "run hive review; on a max_passes-hit REVIEW_STALE row this is the force-retry gesture — clears the marker + reruns after you've edited the focal escalations file (Enter on the same row opens that file in $EDITOR)" },
        { mode: :grid, key: "P", action: :"open-pr",     description: "run hive open-pr (capital so it doesn't collide with plan)" },
        { mode: :grid, key: "A", action: :artifacts,     description: "run hive artifacts (capital so it doesn't collide with archive)" },
        { mode: :grid, key: "F", action: :finalize,      description: "run hive finalize" },
        { mode: :grid, key: "a", action: :archive,       description: "run hive archive" },
        # Grid mode — navigation + sub-modes.
        { mode: :grid, key: "j",         action: :cursor_down,        description: "cursor down (left pane: project; right pane: task row)" },
        { mode: :grid, key: "k",         action: :cursor_up,          description: "cursor up (left pane: project; right pane: task row)" },
        { mode: :grid, key: "g",         action: :cursor_jump_top,    description: "jump to the top of the focused pane" },
        { mode: :grid, key: "G",         action: :cursor_jump_bottom, description: "jump to the bottom of the focused pane" },
        { mode: :grid, key: "Tab",       action: :pane_focus_toggle,  description: "toggle pane focus (left ↔ right)" },
        { mode: :grid, key: "Shift+Tab", action: :pane_focus_toggle,  description: "toggle pane focus (same as Tab)" },
        { mode: :grid, key: "h",         action: :pane_focus_left,    description: "jump focus to the projects pane" },
        { mode: :grid, key: "Left",      action: :pane_focus_left,    description: "jump focus to the projects pane (two-pane layout only)" },
        { mode: :grid, key: "l",         action: :pane_focus_right,   description: "jump focus to the tasks pane" },
        { mode: :grid, key: "Right",     action: :pane_focus_right,   description: "jump focus to the tasks pane" },
        { mode: :grid, key: "Enter",     action: :open_contextual,    description: "left pane: focus right. right pane: open red-status detail on gated red rows; wall_clock REVIEW_STALE keeps direct retry, kill-class ERROR opens log tail, max_passes REVIEW_STALE opens focal escalations; non-red contextual behavior is unchanged" },
        { mode: :grid, key: "o",         action: :open_task_folder,   description: "open the focused task's folder in $EDITOR (read-only browse — no workflow dispatch, distinct from Enter and the verb keys)" },
        { mode: :grid, key: "i",         action: :open_idea_preview,  description: "preview the original idea text for the focused task in the bottom strip" },
        { mode: :grid, key: "s",         action: :open_in_agent,      description: "steer the focused task manually — opens the project's configured development agent in the feature worktree with every stage folder for this slug preloaded as context, marks the task MANUAL_STEERING so headless runs skip it, then archives the slug on agent exit" },
        { mode: :grid, key: "n",         action: :new_idea,           description: "open the new-idea prompt; from ★ All projects, choose a target project first; submitting runs `hive new <project> \"<title>\"`" },
        { mode: :grid, key: "/",         action: :filter,             description: "open filter prompt" },
        { mode: :grid, key: "1-9",       action: :project_scope,      description: "scope to the Nth registered project" },
        { mode: :grid, key: "0",         action: :project_scope,      description: "clear project scope (★ All projects)" },
        { mode: :grid, key: "X",         action: :drop_missing,       description: "drop the scoped project from the registry (same as `hive forget`) — only when shown as `(missing)`; healthy projects are refused" },
        { mode: :grid, key: "?",         action: :help,               description: "this help overlay" },
        { mode: :grid, key: "q",         action: :quit,               description: "quit" },
        # Log-tail mode.
        { mode: :log_tail, key: "q",   action: :back, description: "back to grid" },
        { mode: :log_tail, key: "Esc", action: :back, description: "back to grid" },
        # Red-status detail mode.
        { mode: :red_status_detail, key: "Enter", action: :recover,       description: "run hive's automated recovery for this task and close this screen" },
        { mode: :red_status_detail, key: "o",     action: :open_in_agent, description: "open this task in the project's development agent and close this screen" },
        { mode: :red_status_detail, key: "q",     action: :back,          description: "close this screen and return to the grid" },
        { mode: :red_status_detail, key: "Esc",   action: :back,          description: "close this screen and return to the grid" },
        # Filter prompt mode.
        { mode: :filter, key: "Enter", action: :commit_filter, description: "commit typed filter" },
        { mode: :filter, key: "Esc",   action: :cancel_filter, description: "discard typed buffer and return to grid (any committed filter is preserved)" },
        # Idea preview mode.
        { mode: :idea_preview, key: "any", action: :back, description: "any key dismisses the preview" },
        # New-idea prompt mode (v2).
        { mode: :new_idea_project, key: "j/k",     action: :project_cursor,  description: "move through projects for the new idea" },
        { mode: :new_idea_project, key: "Up/Down", action: :project_cursor,  description: "move through projects (arrow keys)" },
        { mode: :new_idea_project, key: "Enter",   action: :choose_project,  description: "choose the highlighted project and continue to the title prompt" },
        { mode: :new_idea_project, key: "Esc",     action: :cancel_new_idea, description: "cancel and return to grid" },
        { mode: :new_idea_project, key: "q",       action: :cancel_new_idea, description: "cancel and return to grid (alias for Esc)" },

        { mode: :new_idea, key: "Enter", action: :submit_new_idea, description: "submit — runs `hive new <project> \"<title>\"` against the project shown in the prompt label" },
        { mode: :new_idea, key: "Esc",   action: :cancel_new_idea, description: "cancel and return to grid; the typed buffer is discarded" }
      ].each(&:freeze).freeze
    end
  end
end
