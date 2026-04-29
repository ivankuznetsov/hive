require "lipgloss"
require "hive/commands/status"
require "hive/tui/styles"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::Grid.render(model) → String`. The
      # returned String is the entire grid frame the runner will hand to
      # Bubble Tea for diffing against the previous frame.
      #
      # Per-row format ("> slug.ljust(36) label.ljust(24) command age")
      # is identical to `hive status`'s text rendering so a side-by-side
      # comparison of the two surfaces lines up. Cursor highlight uses
      # `Styles::CURSOR_HIGHLIGHT.render(line)` (Lipgloss reverse).
      #
      # Lipgloss `Style#render` strips ANSI when stdout is not a tty (U2
      # finding). Tests can therefore pin layout/text but not styling.
      # Visual styling is validated by manual dogfood per R19.
      module Grid
        SLUG_WIDTH = 36
        LABEL_WIDTH = 24

        module_function

        def render(model)
          visible = visible_snapshot(model)
          sections = []
          sections << header_line(model)
          sections << stalled_banner(model) if stalled?(model)

          sections.concat(body_sections(visible, model))

          sections << ""
          sections << status_line(model)

          Lipgloss.join_vertical(Lipgloss::TOP, *sections.compact)
        end

        # ---- Sections ----

        def header_line(model)
          scope_label = model.scope.zero? ? "all" : model.scope.to_s
          filter_label = model.filter.to_s.empty? ? "-" : model.filter
          generated_at = model.snapshot&.generated_at || "-"
          line = "hive tui  scope=#{scope_label}  filter=#{filter_label}  generated_at=#{generated_at}"
          Styles::HEADER.render(line)
        end

        # `last_error` is set by Update.apply on PollFailed and cleared
        # on SnapshotArrived; this banner gives the user a visual cue
        # that the polling thread hit a transient error.
        def stalled?(model)
          !model.last_error.nil?
        end

        def stalled_banner(model)
          err_class = model.last_error.class.name.split("::").last
          err_msg = model.last_error.message.to_s.lines.first&.chomp.to_s[0, 60]
          line = err_msg.empty? ? "[stalled — #{err_class}]" : "[stalled — #{err_class}: #{err_msg}]"
          Styles::STALLED.render(line)
        end

        def body_sections(visible, model)
          if visible.nil? || visible.projects.empty?
            return [ centered_message(model, "(no projects registered; run `hive init <path>`)") ]
          end

          sections = visible.projects.each_with_index.flat_map do |project, project_idx|
            project_section(project, project_idx, model)
          end

          if visible.rows.empty? && !model.filter.to_s.empty?
            sections << centered_message(model, %((no tasks matching "#{model.filter}")))
          end
          sections
        end

        def project_section(project, project_idx, model)
          lines = [ Styles::HEADER.render(project.name.to_s) ]

          if project.error
            lines << "  error: #{project.error}"
            lines << ""
            return lines
          end

          if project.rows.empty?
            lines << "  no active tasks"
            lines << ""
            return lines
          end

          lines.concat(grouped_rows(project, project_idx, model))
          lines << ""
          lines
        end

        # Groups by action_label in `Status::ACTION_LABEL_ORDER`; unknown
        # labels sort last so a future label addition still renders even
        # when the order list hasn't been updated yet.
        def grouped_rows(project, project_idx, model)
          ordered = order_labels(project.rows.map(&:action_label).uniq)
          row_idx_in_project = 0
          out = []
          ordered.each do |label|
            group = project.rows.select { |r| r.action_label == label }
            next if group.empty?

            out << "  #{label}"
            group.each do |row|
              out << task_row_line(row, project_idx, row_idx_in_project, model)
              row_idx_in_project += 1
            end
          end
          out
        end

        def order_labels(labels)
          known = Hive::Commands::Status::ACTION_LABEL_ORDER
          labels.sort_by { |label| known.index(label) || known.length }
        end

        def task_row_line(row, project_idx, row_idx, model)
          highlighted = model.cursor == [ project_idx, row_idx ]
          indicator = highlighted ? ">" : " "
          slug = row.slug.to_s.ljust(SLUG_WIDTH)
          label = row.action_label.to_s.ljust(LABEL_WIDTH)
          command = row.suggested_command || "-"
          age = format_age(row.age_seconds)

          line = "  #{indicator} #{slug} #{label} #{command} #{age}"
          colored = Styles.for_action_key(row.action_key).render(line)
          highlighted ? Styles::CURSOR_HIGHLIGHT.render(colored) : colored
        end

        # Single-place humaniser; matches `hive status` output so the two
        # surfaces never disagree on what "5m" means.
        def format_age(age_seconds)
          seconds = age_seconds.to_i
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m" if seconds < 3600
          return "#{seconds / 3600}h" if seconds < 86_400

          "#{seconds / 86_400}d"
        end

        def centered_message(model, message)
          width = [ model.cols.to_i, message.length ].max
          Lipgloss::Style.new.width(width).align(Lipgloss::CENTER).render(message)
        end

        # Bottom-line: flash takes priority over help hint so user
        # feedback always wins. Flash decay is in Model#flash_active?.
        def status_line(model)
          if model.flash_active?
            Styles::FLASH.render(model.flash.to_s)
          else
            Styles::HINT.render("[?] help  [/] filter  [q] quit")
          end
        end

        # ---- Visible-snapshot derivation ----
        #
        # Apply scope first (collapses to a single project) so the filter
        # operates on the narrower set and the cursor's project_idx is
        # stable against the visible projects list.
        def visible_snapshot(model)
          snap = model.snapshot
          return nil if snap.nil?

          snap.scope_to_project_index(model.scope).filter_by_slug(model.filter)
        end
      end
    end
  end
end
