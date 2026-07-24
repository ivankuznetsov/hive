require "hive"
require "time"
require "hive/archive_filter"
require "hive/commands/status"

module Hive
  module Tui
    # Immutable snapshot of one `hive status` JSON payload, plus the few
    # operations the renderer needs (filter-by-slug, project-scope,
    # row-at-cursor). Every field is preserved verbatim from the JSON so
    # the renderer never re-classifies what the Status command emitted.
    #
    # Built by StateSource on each successful poll and read by the render
    # thread for one frame at a time. Frozen: `#filter_by_slug` and
    # `#scope_to_project_index` return new instances rather than mutating.
    class Snapshot
      # `error` is nil for healthy projects and the JSON's "error" string
      # ("missing_project_path" / "not_initialised") otherwise.
      # `legacy_stage_dirs` carries the JSON's `legacy_stage_dirs` array
      # verbatim ([] when the project is clean) so the renderer can flag
      # projects with task folders stuck under a renamed stage directory
      # without re-walking the filesystem. `legacy_migrate_command`
      # carries the JSON's `legacy_migrate_command` string verbatim
      # ("hive migrate" when legacy_stage_dirs is non-empty; nil
      # otherwise) — agent-facing parity of the text recovery hint.
      ProjectView = Data.define(:name, :path, :hive_state_path, :error, :rows,
                                :legacy_stage_dirs, :legacy_migrate_command) do
        # `legacy_stage_dirs` defaults to `[]` and `legacy_migrate_command`
        # to nil so existing test factories (predating the fields) can keep
        # building ProjectView with the original 5-keyword shape.
        # Production callers in this file always pass them explicitly.
        def initialize(legacy_stage_dirs: [].freeze, legacy_migrate_command: nil, **rest)
          super(legacy_stage_dirs: legacy_stage_dirs,
                legacy_migrate_command: legacy_migrate_command, **rest)
        end
      end

      # Mirrors `Hive::Commands::Status#task_payload` 1:1 plus a
      # `project_name` back-reference so a flat row list stays attributable
      # when projects are flattened in the grid view. The JSON key
      # `"action"` lands on `:action_key` here to avoid the bareword
      # collision with Ruby's `Kernel#action` namespace conventions.
      Row = Data.define(
        :project_name,
        :stage,
        :slug,
        :id,
        :display_name,
        :workflow,
        :depends_on,
        :blocked_by,
        :dependency_stage,
        :blocked,
        :admission_error,
        :folder,
        :state_file,
        :worktree_path,
        :pr_url,
        :attempt_id,
        :task_generation,
        :condition_task_generation,
        :commit_generation,
        :current_attempt,
        :conditions,
        :condition_history,
        :evidence,
        :condition_overrides,
        :condition_gate,
        :condition_migration,
        :condition_provenance,
        :shadow_audit,
        :condition_warning,
        :marker,
        :attrs,
        # Carried verbatim from the JSON `held` object for payload↔Row
        # schema-correspondence only (schema_correspondence_test). The
        # renderer does NOT read this — it derives the hold label from
        # `attrs` via `Hive::AgentLimit.held_label` (tasks_pane.rb). Asymmetric
        # with `blocked`, which IS consumed by the renderer; do not "fix" a
        # hold-label bug by editing `row.held`.
        :held,
        :mtime,
        :observation_mtime,
        :folder_mtime,
        :age_seconds,
        :claude_pid,
        :claude_pid_alive,
        :action_key,
        :action_label,
        :suggested_command,
        :next_action,
        :outcomes,
        :diagnostic,
        :live_task_lock,
        :task_lock_pid,
        :task_lock_process_start_time,
        :task_lock_id,
        :implementation_identity,
        :unanswered_questions
      ) do
        # worktree_path defaults to nil so existing test factories that
        # predate PR #84 finding #8 can keep their existing Row.new
        # calls; production code in build_row always passes the value
        # explicitly. New tests should pass it explicitly too.
        # pr_url defaults to nil so payloads / test factories that predate
        # the PR-link feature keep building Row without it; production
        # payloads always emit the value (string or null) explicitly.
        # live_task_lock defaults to false so older JSON payloads (and
        # tests written before issue #144) keep classifying correctly;
        # production payloads always emit the boolean explicitly.
        # unanswered_questions defaults to 0 so payloads / test factories
        # that predate issue #270 keep working; production payloads always
        # emit the integer explicitly.
        # outcomes defaults to [] for pre-human-stage payloads and factories;
        # current status payloads always emit the descriptor-derived array.
        def initialize(id: nil, display_name: nil, workflow: nil, worktree_path: nil,
                       pr_url: nil, attempt_id: nil, task_generation: nil,
                       condition_task_generation: nil, commit_generation: nil,
                       current_attempt: nil, conditions: [], condition_history: [],
                       evidence: [], condition_overrides: [], condition_gate: nil, condition_migration: nil,
                       condition_provenance: {}, shadow_audit: {}, condition_warning: nil,
                       observation_mtime: nil, folder_mtime: nil, live_task_lock: false,
                       task_lock_pid: nil, task_lock_process_start_time: nil, task_lock_id: nil,
                       implementation_identity: nil,
                       unanswered_questions: 0, outcomes: [], depends_on: nil,
                       blocked_by: nil, dependency_stage: nil,
                       blocked: false, admission_error: nil, held: nil, **rest)
          super(id: id, display_name: display_name,
                workflow: workflow,
                depends_on: depends_on,
                blocked_by: blocked_by,
                dependency_stage: dependency_stage,
                blocked: blocked,
                admission_error: admission_error,
                worktree_path: worktree_path,
                pr_url: pr_url,
                attempt_id: attempt_id,
                task_generation: task_generation,
                condition_task_generation: condition_task_generation,
                commit_generation: commit_generation,
                current_attempt: current_attempt,
                conditions: conditions,
                condition_history: condition_history,
                evidence: evidence,
                condition_overrides: condition_overrides,
                condition_gate: condition_gate,
                condition_migration: condition_migration,
                condition_provenance: condition_provenance,
                shadow_audit: shadow_audit,
                condition_warning: condition_warning,
                held: held,
                observation_mtime: observation_mtime,
                folder_mtime: folder_mtime,
                live_task_lock: live_task_lock,
                task_lock_pid: task_lock_pid,
                task_lock_process_start_time: task_lock_process_start_time,
                task_lock_id: task_lock_id,
                implementation_identity: implementation_identity,
                unanswered_questions: unanswered_questions,
                outcomes: outcomes, **rest)
        end
      end

      attr_reader :generated_at, :projects

      def initialize(generated_at:, projects:)
        @generated_at = generated_at
        @projects = projects.freeze
        freeze
      end

      # Tolerant constructor: missing keys default to nil; unknown keys
      # ignored. `generated_at` is preserved verbatim (string from JSON).
      def self.from_payload(payload)
        payload ||= {}
        project_payloads = Array(payload["projects"])
        projects = project_payloads.map { |p| build_project_view(p) }
        new(generated_at: payload["generated_at"], projects: projects)
      end

      # Rows are sorted by `Status::ACTION_LABEL_ORDER` at construction so
      # `row_at(cursor)` and the renderer's grouped-row traversal walk the
      # same list. Without this, a project whose tasks span multiple
      # action_labels has the cursor highlight one row while keystrokes
      # act on another (issue #10). Unknown labels sort last but preserve
      # JSON order against their unknown peers; within a known group the
      # original JSON order is preserved so Status's mtime-desc ranking
      # within a stage is honoured.
      def self.build_project_view(payload)
        payload ||= {}
        name = payload["name"]
        indexed = Array(payload["tasks"]).map.with_index { |t, i| [ build_row(t, name), i ] }
        order = Hive::Commands::Status::ACTION_LABEL_ORDER
        sorted = indexed.sort_by do |row, idx|
          pos = order.index(row.action_label) || order.length
          [ pos, idx ]
        end.map(&:first)
        ProjectView.new(
          name: name,
          path: payload["path"],
          hive_state_path: payload["hive_state_path"],
          error: payload["error"],
          rows: sorted.freeze,
          legacy_stage_dirs: Array(payload["legacy_stage_dirs"]).freeze,
          legacy_migrate_command: payload["legacy_migrate_command"]
        ).freeze
      end

      def self.build_row(payload, project_name)
        payload ||= {}
        Row.new(
          project_name: project_name,
          stage: payload["stage"],
          slug: payload["slug"],
          id: payload["id"],
          display_name: payload["display_name"],
          workflow: payload["workflow"],
          depends_on: payload["depends_on"],
          blocked_by: payload["blocked_by"],
          dependency_stage: payload["dependency_stage"],
          blocked: payload["blocked"] == true,
          admission_error: payload["admission_error"],
          folder: payload["folder"],
          state_file: payload["state_file"],
          worktree_path: payload["worktree_path"],
          pr_url: payload["pr_url"],
          attempt_id: payload["attempt_id"],
          task_generation: payload["task_generation"],
          condition_task_generation: payload["condition_task_generation"],
          commit_generation: payload["commit_generation"],
          current_attempt: payload["current_attempt"],
          conditions: Array(payload["conditions"]).freeze,
          condition_history: Array(payload["condition_history"]).freeze,
          evidence: Array(payload["evidence"]).freeze,
          condition_overrides: Array(payload["condition_overrides"]).freeze,
          condition_gate: payload["condition_gate"],
          condition_migration: payload["condition_migration"],
          condition_provenance: payload["condition_provenance"] || {},
          shadow_audit: payload["shadow_audit"] || {},
          condition_warning: payload["condition_warning"],
          marker: payload["marker"],
          attrs: payload["attrs"],
          held: payload["held"],
          mtime: payload["mtime"],
          observation_mtime: payload["observation_mtime"],
          folder_mtime: payload["folder_mtime"],
          age_seconds: payload["age_seconds"],
          claude_pid: payload["claude_pid"],
          claude_pid_alive: payload["claude_pid_alive"],
          action_key: payload["action"],
          action_label: payload["action_label"],
          suggested_command: payload["suggested_command"],
          next_action: payload["next_action"],
          outcomes: Array(payload["outcomes"]).freeze,
          diagnostic: payload["diagnostic"],
          live_task_lock: payload["live_task_lock"] == true,
          task_lock_pid: payload["task_lock_pid"],
          task_lock_process_start_time: payload["task_lock_process_start_time"],
          task_lock_id: payload["task_lock_id"],
          implementation_identity: payload["implementation_identity"],
          unanswered_questions: payload["unanswered_questions"].to_i
        ).freeze
      end

      # Flat list of all rows across all projects, in registry order then
      # JSON row order. The grid view consumes this directly.
      def rows
        @projects.flat_map(&:rows)
      end

      # Case-insensitive substring filter on each row's slug, display name,
      # or id. Empty
      # substring is a no-op (returns self). Projects with zero matches
      # are kept with `rows: []` so the renderer can still show their
      # error/empty state.
      def filter_by_slug(substring)
        return self if substring.nil? || substring.empty?

        needle = substring.downcase
        filtered = @projects.map do |project|
          matched = project.rows.select do |row|
            [
              row.slug,
              row.display_name,
              row.id
            ].any? { |value| value.to_s.downcase.include?(needle) }
          end
          ProjectView.new(
            name: project.name,
            path: project.path,
            hive_state_path: project.hive_state_path,
            error: project.error,
            rows: matched.freeze,
            legacy_stage_dirs: project.legacy_stage_dirs,
            legacy_migrate_command: project.legacy_migrate_command
          ).freeze
        end
        self.class.new(generated_at: @generated_at, projects: filtered)
      end

      def without_old_archived(now: Time.now)
        filtered = @projects.map do |project|
          rows = project.rows.reject { |row| old_archived_row?(row, now: now) }
          project.with(rows: rows.freeze)
        end
        self.class.new(generated_at: @generated_at, projects: filtered)
      end

      def hidden_old_archived_count(now: Time.now)
        rows.count { |row| old_archived_row?(row, now: now) }
      end

      # `n == 0` is "all projects" (returns self). `n` between 1 and
      # projects.size returns a single-project snapshot (1-indexed). Out
      # of range returns an empty-projects snapshot so the renderer can
      # show a clean empty-state.
      def scope_to_project_index(n)
        return self if n.zero?

        if n.between?(1, @projects.size)
          self.class.new(generated_at: @generated_at, projects: [ @projects[n - 1] ])
        else
          self.class.new(generated_at: @generated_at, projects: [])
        end
      end

      # The canonical "what the operator can see and act on" projection:
      # scope to the focused project, apply the slug filter, then drop
      # old archived rows. Centralised so every cursor/render site shares
      # one definition — a projection that forgets `.without_old_archived`
      # would let the cursor act on a hidden row.
      def visible_projection(scope:, filter:, now: Time.now)
        scope_to_project_index(scope)
          .filter_by_slug(filter)
          .without_old_archived(now: now)
      end

      # `cursor` is `[project_idx, row_idx]` (both 0-based) or nil. Returns
      # nil for any out-of-range coordinate so the renderer can treat
      # "nothing selected" uniformly.
      def row_at(cursor)
        return nil if cursor.nil?

        project_idx, row_idx = cursor
        return nil if project_idx.nil? || row_idx.nil?
        return nil unless project_idx.between?(0, @projects.size - 1)

        project_rows = @projects[project_idx].rows
        return nil unless row_idx.between?(0, project_rows.size - 1)

        project_rows[row_idx]
      end

      private

      def old_archived_row?(row, now:)
        Hive::ArchiveFilter.hide?(
          stage: row.stage,
          mtime: parse_time(row.mtime),
          folder_mtime: parse_folder_mtime(row.folder_mtime),
          now: now
        )
      end

      def parse_folder_mtime(value)
        parse_time(value)
      end

      def parse_time(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
