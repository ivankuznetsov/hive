# frozen_string_literal: true

module Hive
  # Internal presentation boundary shared by `hive status` and the TUI.
  # It owns action-label ordering so command grouping and snapshot sorting
  # cannot drift onto separate lists.
  #
  # The module is internal: it defines no I/O, holds no state, and is not
  # part of the public gem surface. Consumers must require it explicitly.
  module StatusProjection
    # Canonical presentation order for status action labels. Rows with a
    # label earlier in this list sort first; unknown labels sort last but
    # preserve payload order against their unknown peers. See
    # `.label_position`.
    ACTION_LABEL_ORDER = [
      "Admission error",
      "Ready to brainstorm",
      # Generic-workflow actions (non-coding descriptors). Sorted high with
      # the other actionable "ready"/"needs" rows so generic status rows
      # don't fall to the bottom (below "Error") as unknown labels would.
      "Ready to run",
      "Ready to advance",
      # Per-stage "needs input" labels (the differentiated NEEDS_INPUT rows
      # plus the shared generic "Needs your input"). Deliberately ordered
      # between "Ready to advance" and "Ready to plan" so these actionable
      # rows sort high alongside the other "ready"/"needs" rows.
      "Answer questions",
      "Review plan draft",
      "Needs your input",
      "Awaiting human decision",
      "Needs review decision",
      "Confirm finalize",
      "Ready to plan",
      "Plan review in progress",
      "Plan review retry ready",
      "Plan review retry scheduled",
      "Plan review needs an operator decision",
      "Plan review cleared with degraded coverage",
      "Plan reviewer configuration required",
      "Plan review blocks execution",
      "Ready to develop",
      "Implementation rework required",
      "Needs recovery",
      "Retry draft PR handoff manually",
      "Agent running",
      "Ready to open PR",
      "Ready for review",
      "Ready to collect artifacts",
      # Clean ad-hoc PR review parked at 6-review (REVIEW_PARKED): complete and
      # non-advancing, so it sorts with the other review-complete rows rather
      # than falling below "Error" as an unknown label.
      "Ad-hoc review complete (parked)",
      "Rejected (parked)",
      "Blocked (parked)",
      "Escalated (parked)",
      "Ready to finalize",
      "Ready to archive",
      "Archived",
      "Manually steered",
      "Blocked",
      "Error"
    ].freeze

    # Sort position for one action label: its index in
    # `ACTION_LABEL_ORDER`, or "last" for unknown labels. Callers tie-break
    # on their own stable secondary key (e.g. original payload order).
    def self.label_position(label)
      ACTION_LABEL_ORDER.index(label) || ACTION_LABEL_ORDER.length
    end
  end
end
