require "hive/tui/model"
require "hive/tui/red_status_detail_keys"

module Hive
  module Tui
    # Pure layout math for the `:red_status_detail` view. Shared by
    # `Views::RedStatusDetail` and `Update` so log-scroll clamping
    # follows the same two-action detail-screen composition.
    module RedStatusDetailLayout
      # Trailing byte window the log-panel snapshot pulls from the file.
      # Shared with `BubbleModel#red_status_detail_log_snapshot` and the
      # rendered panel title so a tuning bump propagates without drift.
      LOG_SNAPSHOT_BACKBUFFER_BYTES = 64 * 1024
      LOG_SNAPSHOT_BACKBUFFER_LABEL = "#{LOG_SNAPSHOT_BACKBUFFER_BYTES / 1024} KiB tail".freeze

      MIN_LOG_PANEL_ROWS = 4
      MAX_LOG_PANEL_ROWS = 12
      AGENT_FALLBACK = Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK

      module_function

      def footer_row_count(width)
        Hive::Tui::RedStatusDetailKeys::FOOTER.length <= width ? 1 : Hive::Tui::RedStatusDetailKeys::ACTION_KEYS.length
      end

      def chip_labels(agent_label)
        label = agent_label.to_s.empty? ? AGENT_FALLBACK : agent_label.to_s
        [
          "[Enter] Recover — re-run hive's automated recovery for this task",
          "[o]     Open in agent — launch #{label} in the task worktree"
        ]
      end

      def action_row_count(agent_label, width)
        max_width = [ width.to_i, 1 ].max
        lines = 0
        current = 0
        chip_labels(agent_label).each do |label|
          length = [ label.length, max_width ].min
          candidate = current.zero? ? length : current + 1 + length
          if candidate <= max_width
            current = candidate
          else
            lines += 1 if current.positive?
            current = length
          end
        end
        lines += 1 if current.positive?
        lines
      end

      def artifact_row_count(row)
        paths = Array(row&.diagnostic && row.diagnostic["artifact_paths"])
        return 0 if paths.empty?

        1 + 1 + [ paths.length, 5 ].min + (paths.length > 5 ? 1 : 0)
      end

      def log_panel_visible?(available_rows, has_lines)
        has_lines && available_rows >= MIN_LOG_PANEL_ROWS + 2
      end

      def log_height_budget(available_rows)
        [[ available_rows - 2, MIN_LOG_PANEL_ROWS ].max, MAX_LOG_PANEL_ROWS ].min
      end
    end
  end
end
