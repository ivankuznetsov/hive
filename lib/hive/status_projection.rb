# frozen_string_literal: true

module Hive
  # Internal status projection boundary shared by the `hive status` command
  # and its read-only consumers (TUI snapshot/state source, daemon and web
  # feeds). This module — not any single caller — owns the two decisions
  # that used to leak across the command/TUI boundary:
  #
  # 1. Presentation ordering of action labels (`ACTION_LABEL_ORDER`), which
  #    `Commands::Status` re-exports for its own label grouping and which
  #    `Tui::Snapshot` applies when ordering rows at construction time.
  # 2. Composition of archive-aware payload variants from an ordinary
  #    Status payload plus a frozen archived-row cache, so callers never
  #    reinterpret raw task arrays or hidden-archive counts themselves.
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
      "Publication blocked by secret policy",
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

    # Rebuilds an ordinary Status payload whose per-project task lists are
    # replaced with the full archived rows from `archived_cache` (an
    # unfiltered-archive cache built by the TUI state source). Projects in
    # error degrade to an empty task list; the ordinary payload's hidden
    # counts are dropped because every cached row is visible here. The
    # input payloads are treated as immutable: projects are duplicated,
    # never mutated.
    def self.archive_payload_from_cache(ordinary_payload, archived_cache)
      cached_rows_by_path = archived_cache.fetch(:rows_by_path)
      copy = ordinary_payload.dup
      copy["projects"] = Array(ordinary_payload["projects"]).map do |project|
        project_copy = project.dup
        cached_rows = project["error"] ? [] : cached_rows_by_path.fetch(project["path"], [])
        project_copy["tasks"] = cached_rows
        project_copy.delete("hidden_archived_task_count")
        project_copy
      end
      copy
    end

    # Merges the still-visible archived rows from `archived_cache` into an
    # active-only Status payload: visible archived rows are appended unless
    # an active row already occupies the same folder, and each project's
    # `hidden_archived_task_count` is restated from the cache. Erroring
    # projects contribute no rows and a zero hidden count. As with
    # `.archive_payload_from_cache`, inputs are duplicated, never mutated.
    def self.merge_visible_archived_payload(active_payload, archived_cache)
      visible_rows_by_path = archived_cache.fetch(:visible_rows_by_path)
      hidden_counts_by_path = archived_cache.fetch(:hidden_counts_by_path)
      copy = active_payload.dup
      copy["projects"] = Array(active_payload["projects"]).map do |project|
        project_copy = project.dup
        active_rows = Array(project["tasks"])
        active_folders = active_rows.to_h { |row| [ row["folder"], true ] }
        cached_rows =
          if project["error"]
            []
          else
            visible_rows_by_path.fetch(project["path"], [])
          end
        project_copy["tasks"] =
          active_rows + cached_rows.reject { |row| active_folders.key?(row["folder"]) }
        project_copy["hidden_archived_task_count"] =
          project["error"] ? 0 : hidden_counts_by_path.fetch(project["path"], 0)
        project_copy
      end
      copy
    end
  end
end
