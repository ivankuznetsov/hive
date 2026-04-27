require "hive"

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
      :mode,           # Symbol: :grid / :triage / :log_tail / :filter / :help
      :snapshot,       # Hive::Tui::Snapshot (or nil before first poll)
      :cursor,         # [project_idx, row_idx] (or nil for empty grid)
      :filter,         # String or nil — committed substring filter
      :filter_buffer,  # String — typed text in :filter mode
      :scope,          # Integer — 0 means all projects; 1..N selects Nth
      :flash,          # String or nil — current status-line message
      :flash_set_at,   # Time or nil — flash decay timestamp
      :triage_state,   # Hive::Tui::TriageState or nil — :triage mode only
      :tail_state,     # Hive::Tui::LogTail::Tail or nil — :log_tail mode only
      :cols,           # Integer — terminal width (set on WindowSized)
      :rows,           # Integer — terminal height
      :last_error      # Exception or nil — last poll failure
    )

    Model::DEFAULT_FLASH_TTL_SECONDS = 5.0

    class Model
      # Boot state. App.run constructs the runner with this Model.
      def self.initial(cols: 80, rows: 24)
        new(
          mode: :grid,
          snapshot: nil,
          cursor: [ 0, 0 ],
          filter: nil,
          filter_buffer: "",
          scope: 0,
          flash: nil,
          flash_set_at: nil,
          triage_state: nil,
          tail_state: nil,
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
