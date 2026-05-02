require "hive/workflows"

module Hive
  module Tui
    # Single source of truth for the keybinding cheatsheet shown in the
    # `?` help overlay. Each entry's `:action` is either a workflow-verb
    # symbol (cross-checked against `Hive::Workflows::VERBS` in the
    # unit test so a verb rename in `Workflows` breaks compile here) or
    # a TUI-internal symbol (filter / project_scope / help / quit /
    # back / open_findings / etc.). The `:mode` field groups bindings
    # in the help overlay so the renderer can show "Triage mode: a /
    # r" separately from "Grid mode: a (archive) / r (review)".
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
        { mode: :grid, key: "r", action: :review,        description: "run hive review" },
        { mode: :grid, key: "P", action: :pr,            description: "run hive pr (capital so it doesn't collide with plan)" },
        { mode: :grid, key: "a", action: :archive,       description: "run hive archive" },
        # Grid mode — navigation + sub-modes.
        { mode: :grid, key: "j",         action: :cursor_down,        description: "cursor down (left pane: project; right pane: task row)" },
        { mode: :grid, key: "k",         action: :cursor_up,          description: "cursor up (left pane: project; right pane: task row)" },
        { mode: :grid, key: "Tab",       action: :pane_focus_toggle,  description: "toggle pane focus (left ↔ right)" },
        { mode: :grid, key: "Shift+Tab", action: :pane_focus_toggle,  description: "toggle pane focus (same as Tab)" },
        { mode: :grid, key: "h",         action: :pane_focus_left,    description: "jump focus to the projects pane" },
        { mode: :grid, key: "l",         action: :pane_focus_right,   description: "jump focus to the tasks pane" },
        { mode: :grid, key: "Enter",     action: :open_contextual,    description: "left pane: focus right. right pane: open contextual mode (triage / log tail) or dispatch the suggested command" },
        { mode: :grid, key: "n",         action: :new_idea,           description: "open the new-idea prompt; submitting runs `hive new <project> \"<title>\"`" },
        { mode: :grid, key: "/",         action: :filter,             description: "open filter prompt" },
        { mode: :grid, key: "1-9",       action: :project_scope,      description: "scope to the Nth registered project" },
        { mode: :grid, key: "0",         action: :project_scope,      description: "clear project scope (★ All projects)" },
        { mode: :grid, key: "?",         action: :help,               description: "this help overlay" },
        { mode: :grid, key: "q",         action: :quit,               description: "quit" },
        # Triage mode — Space and bulk rebindings.
        { mode: :triage, key: "j",     action: :cursor_down,    description: "finding cursor down" },
        { mode: :triage, key: "k",     action: :cursor_up,      description: "finding cursor up" },
        { mode: :triage, key: "Space", action: :toggle_finding, description: "toggle accept/reject on the highlighted finding" },
        { mode: :triage, key: "d",     action: :develop,        description: "dispatch hive develop to re-inject accepted findings" },
        { mode: :triage, key: "a",     action: :accept_all,     description: "bulk accept every finding (rebound from grid-mode archive)" },
        { mode: :triage, key: "r",     action: :reject_all,     description: "bulk reject every finding (rebound from grid-mode review)" },
        { mode: :triage, key: "Esc",   action: :back,           description: "back to grid" },
        # Log-tail mode.
        { mode: :log_tail, key: "q",   action: :back, description: "back to grid" },
        { mode: :log_tail, key: "Esc", action: :back, description: "back to grid" },
        # Filter prompt mode.
        { mode: :filter, key: "Enter", action: :commit_filter, description: "commit typed filter" },
        { mode: :filter, key: "Esc",   action: :cancel_filter, description: "discard typed buffer and return to grid (any committed filter is preserved)" },
        # New-idea prompt mode (v2).
        { mode: :new_idea, key: "Enter", action: :submit_new_idea, description: "submit — runs `hive new <project> \"<title>\"` against the project shown in the prompt label" },
        { mode: :new_idea, key: "Esc",   action: :cancel_new_idea, description: "cancel and return to grid; the typed buffer is discarded" }
      ].each(&:freeze).freeze
    end
  end
end
