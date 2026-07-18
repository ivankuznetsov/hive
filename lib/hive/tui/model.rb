require "hive"
require "hive/tui/composer_staging"

module Hive
  module Tui
    # Unified application state for the Charm backend's MVU loop. Every
    # state transition flows through `Hive::Tui::Update.apply(model, msg)`
    # and produces a new Model. Views (in U7+) read the Model and return
    # a String — they never read or write state outside this record.
    #
    # Mode is a Symbol selecting which view renders and how `KeyPressed`
    # gets interpreted. Help is `:help` rather than a separate boolean
    # flag (resolves the doc-review coherence finding about `show_help`).
    #
    # Frozen value object built on `Data.define`. `#with(**)` returns a
    # new Model with overridden fields — never mutate.
    # Default flash TTL — long enough that the user reads a verb-exit
    # flash without effort, short enough that it doesn't linger past
    # the next keystroke. Renderer + Tick handler both read this constant.
    # Lifted out of the Data.define block because Ruby's Data.define
    # block-scope doesn't bind constants to the resulting class.
    Model = Data.define(
      :mode,             # Symbol: :grid / :log_tail / :filter / :help / :new_idea_project / :new_idea / :idea_preview / :red_status_detail / :implementation_identity_detail / :token_stats / :archive
      :snapshot,         # Hive::Tui::Snapshot (or nil before first poll)
      :cursor,           # [project_idx, row_idx] (or nil for empty grid)
      :filter,           # String or nil — committed substring filter
      :filter_buffer,    # String — typed text in :filter mode
      :scope,            # Integer — 0 means all projects; 1..N selects Nth
      :pane_focus,       # Symbol: :left | :right (v2 two-pane layout)
      :new_idea_project_name, # String or nil — explicit target chosen from ★ All
      :new_idea_project_cursor, # Integer — selection cursor in :new_idea_project mode
      :new_idea_buffer,  # String — typed text in :new_idea mode
      :new_idea_cursor,  # Integer — character index within new_idea_buffer
      :new_idea_attachments, # Array<Model::Attachment> — staged image refs for :new_idea
      :new_idea_staging_dir, # String or nil — temp dir holding staged image files
      :new_idea_staging_tmp_root, # String or nil — tmp root captured when staging dir was created
      # Integer — monotonic-per-composer counter; never decrements on
      # prune. Used to derive `[imageN]` labels so a prune-then-paste
      # cycle cannot re-use a label and overwrite a previously staged
      # asset. Resets only on open / cancel / submit.
      :new_idea_attachment_counter,
      :new_idea_broken_labels, # Array<String> — labels highlighted after rich-submit validation fails
      :info_panel_state, # Model::InfoPanelState or nil — read-only :idea_preview payload
      :flash,            # String or nil — current status-line message
      :flash_set_at,     # Time or nil — flash decay timestamp
      :tail_state,       # Hive::Tui::LogTail::Tail or nil — :log_tail mode only
      :red_status_detail_state, # Model::RedStatusDetailState or nil — :red_status_detail mode only
      :implementation_identity_detail_state, # Model::ImplementationIdentityDetailState or nil
      :token_stats_state, # Model::TokenStatsState or nil — :token_stats mode only
      :help_scroll_offset, # Integer — scroll offset for :help; clamped by Update and reset on open
      :cols,             # Integer — terminal width (set on WindowSized)
      :rows,             # Integer — terminal height
      :last_error        # Exception or nil — last poll failure
    )

    Model::DEFAULT_FLASH_TTL_SECONDS = 5.0

    # Single source of truth for the v2 two-pane width threshold. Below
    # this value the projects pane is suppressed (single-pane fallback)
    # AND focus is forced to :right (the only visible surface). Both
    # invariants must agree — defining the constant once here prevents
    # render layer (BubbleModel#compose_two_pane_view) and focus layer
    # (Update#apply_pane_focus_*) from drifting out of sync.
    Model::TWO_PANE_MIN_COLS = 70
    # Model-wide buffer cap for the new-idea composer. Enforced in the
    # single insert helper `Update.insert_new_idea_text` and the paste
    # gate `BubbleModel#stage_image`; do not re-implement the check at
    # callers — route new insertion paths through one of those two
    # sites so the invariant has one source of truth.
    Model::NEW_IDEA_BUFFER_MAX_CHARS = 4096
    # `:ext` is the canonical, lowercased + leading-dot-stripped
    # extension chosen at staging time (via
    # `Hive::Tui::ComposerStaging.normalized_extension`). It is
    # authoritative for the body-markdown extension and the on-disk
    # asset basename — derivation from `staging_path` is intentionally
    # avoided so a future rename/move of the staging file cannot let
    # the body markdown extension drift away from the on-disk copy.
    Model::Attachment = Data.define(:label, :staging_path, :ext) do
      # Canonicalize `ext` once at construction so callers can trust the
      # field's documented invariant ("lowercased, leading-dot stripped,
      # `png` fallback") instead of every reader re-normalizing.
      def initialize(label:, staging_path:, ext:)
        super(
          label: label,
          staging_path: staging_path,
          ext: Hive::Tui::ComposerStaging.normalized_extension(ext)
        )
      end
    end

    Model::InfoPanelState = Data.define(
      :slug,
      :stage,
      :created_at,
      :original_text,
      :folder_path,
      :latest_log_path,
      :stage_extra
    )

    Model::RedStatusDetailState = Data.define(
      :row,
      :agent_label,
      :log_path,
      :log_lines,
      :log_scroll_offset
    )
    # Single source of truth for the "no resolved label" copy. The
    # resolver in BubbleModel falls back to this string when project
    # config / agent lookup fails, so the view can render `agent_label`
    # directly without re-applying a render-time `|| AGENT_FALLBACK`.
    Model::RedStatusDetailState::AGENT_FALLBACK = "your project's development agent".freeze
    class Model::RedStatusDetailState
      def initialize(row:, agent_label: AGENT_FALLBACK, log_path: nil, log_lines: [], log_scroll_offset: 0)
        super
      end
    end

    Model::TokenStatsState = Data.define(:scope_level, :project_slug, :task_slug) do
      def initialize(scope_level:, project_slug: nil, task_slug: nil)
        super(
          scope_level: scope_level,
          project_slug: project_slug,
          task_slug: task_slug
        )
      end
    end

    Model::ImplementationIdentityDetailState = Data.define(:row)

    class Model
      # Boot state. App.run constructs the runner with this Model.
      # `pane_focus` defaults to `:right` so the table is the first
      # interaction surface — preserves v1 muscle memory where verb keys
      # (b/p/d/r/P/a) and Enter operate on the highlighted task without
      # the user first having to Tab into the task pane.
      def self.initial(cols: 80, rows: 24)
        new(
          mode: :grid,
          snapshot: nil,
          cursor: [ 0, 0 ],
          filter: nil,
          filter_buffer: "",
          scope: 0,
          pane_focus: :right,
          new_idea_project_name: nil,
          new_idea_project_cursor: 0,
          new_idea_buffer: "",
          new_idea_cursor: 0,
          new_idea_attachments: [],
          new_idea_staging_dir: nil,
          new_idea_staging_tmp_root: nil,
          new_idea_attachment_counter: 0,
          new_idea_broken_labels: [],
          info_panel_state: nil,
          flash: nil,
          flash_set_at: nil,
          tail_state: nil,
          red_status_detail_state: nil,
          implementation_identity_detail_state: nil,
          token_stats_state: nil,
          help_scroll_offset: 0,
          cols: cols,
          rows: rows,
          last_error: nil
        )
      end

      # True when the flash message is within its TTL and should render
      # in the status line. Read by views; updated by Update on Tick.
      def flash_active?(now: Time.now, ttl: DEFAULT_FLASH_TTL_SECONDS)
        return false if flash.nil? || flash_set_at.nil?

        (now - flash_set_at) < ttl
      end
    end
  end
end
