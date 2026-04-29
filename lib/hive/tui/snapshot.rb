require "hive"
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
      ProjectView = Data.define(:name, :path, :hive_state_path, :error, :rows)

      # Mirrors `Hive::Commands::Status#task_payload` 1:1 plus a
      # `project_name` back-reference so a flat row list stays attributable
      # when projects are flattened in the grid view. The JSON key
      # `"action"` lands on `:action_key` here to avoid the bareword
      # collision with Ruby's `Kernel#action` namespace conventions.
      Row = Data.define(
        :project_name,
        :stage,
        :slug,
        :folder,
        :state_file,
        :marker,
        :attrs,
        :mtime,
        :age_seconds,
        :claude_pid,
        :claude_pid_alive,
        :action_key,
        :action_label,
        :suggested_command
      )

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
          rows: sorted.freeze
        ).freeze
      end

      def self.build_row(payload, project_name)
        payload ||= {}
        Row.new(
          project_name: project_name,
          stage: payload["stage"],
          slug: payload["slug"],
          folder: payload["folder"],
          state_file: payload["state_file"],
          marker: payload["marker"],
          attrs: payload["attrs"],
          mtime: payload["mtime"],
          age_seconds: payload["age_seconds"],
          claude_pid: payload["claude_pid"],
          claude_pid_alive: payload["claude_pid_alive"],
          action_key: payload["action"],
          action_label: payload["action_label"],
          suggested_command: payload["suggested_command"]
        ).freeze
      end

      # Flat list of all rows across all projects, in registry order then
      # JSON row order. The grid view consumes this directly.
      def rows
        @projects.flat_map(&:rows)
      end

      # Case-insensitive substring filter on each row's slug. Empty
      # substring is a no-op (returns self). Projects with zero matches
      # are kept with `rows: []` so the renderer can still show their
      # error/empty state.
      def filter_by_slug(substring)
        return self if substring.nil? || substring.empty?

        needle = substring.downcase
        filtered = @projects.map do |project|
          matched = project.rows.select { |row| row.slug.to_s.downcase.include?(needle) }
          ProjectView.new(
            name: project.name,
            path: project.path,
            hive_state_path: project.hive_state_path,
            error: project.error,
            rows: matched.freeze
          ).freeze
        end
        self.class.new(generated_at: @generated_at, projects: filtered)
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
    end
  end
end
