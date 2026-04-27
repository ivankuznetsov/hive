require "curses"
require "hive/tui/render/palette"

module Hive
  module Tui
    module Render
      # Findings triage renderer. Draws one frame per call against a
      # `TriageState`: header with the review file basename and slug,
      # findings grouped by `Hive::Findings::KNOWN_SEVERITIES`, each row
      # rendered `[ ] #ID title — justification` with the cursor row
      # under `Curses::A_REVERSE`. Bottom line is the flash-or-help
      # status line, mirroring `Render::Grid`'s contract so the user
      # sees subprocess feedback in the same place.
      #
      # Severity-tinted color pairs are deferred to a v2 polish; every
      # finding row uses `Palette::PAIR_DEFAULT` for now (the cursor
      # already gets emphasis via A_REVERSE).
      class Triage
        SEVERITY_ORDER = %w[high medium low nit].freeze
        # Header reserves rows 0-1, status line takes the last row;
        # findings start at row 2.
        FIRST_FINDING_ROW = 2

        def initialize
          @flash_message = nil
        end

        def draw(triage_state, slug:, review_path:)
          Curses.erase
          draw_header(slug: slug, review_path: review_path)
          if triage_state.findings.empty?
            draw_centered_message("(no findings in this review file)", FIRST_FINDING_ROW + 1)
          else
            draw_findings(triage_state)
          end
          draw_status_line
          Curses.refresh
        end

        # Buffer a one-shot status-line message for the next draw. The
        # message clears after that draw so transient subprocess errors
        # don't linger past the next user keystroke.
        def flash!(message)
          @flash_message = message
        end

        private

        def draw_header(slug:, review_path:)
          line = "#{File.basename(review_path)} — #{slug}"
          with_attr(Curses::A_BOLD) { put(0, 0, line) }
        end

        def draw_findings(triage_state)
          row_cursor = FIRST_FINDING_ROW
          grouped = group_by_severity(triage_state.findings)
          SEVERITY_ORDER.each do |severity|
            section = grouped[severity]
            next if section.nil? || section.empty?

            with_attr(Curses::A_BOLD) { put(row_cursor, 0, "## #{severity.capitalize}") }
            row_cursor += 1
            section.each do |entry|
              draw_finding_row(entry[:finding], entry[:index], triage_state.cursor, row_cursor)
              row_cursor += 1
            end
            row_cursor += 1
          end
          # Render any findings whose severity isn't in SEVERITY_ORDER
          # under an "Other" group so a malformed reviewer file still
          # surfaces every row instead of silently dropping it.
          others = triage_state.findings.each_with_index.reject { |f, _| SEVERITY_ORDER.include?(f.severity) }
          render_others(others, triage_state.cursor, row_cursor) unless others.empty?
        end

        def render_others(others, cursor, row_cursor)
          with_attr(Curses::A_BOLD) { put(row_cursor, 0, "## Other") }
          row_cursor += 1
          others.each do |finding, idx|
            draw_finding_row(finding, idx, cursor, row_cursor)
            row_cursor += 1
          end
        end

        # Group preserves the original index inside the flat findings
        # array so the cursor (which indexes the flat array, not the
        # per-severity bucket) still highlights the right row.
        def group_by_severity(findings)
          grouped = Hash.new { |h, k| h[k] = [] }
          findings.each_with_index do |f, idx|
            grouped[f.severity] << { finding: f, index: idx }
          end
          grouped
        end

        def draw_finding_row(finding, finding_index, cursor_index, screen_row)
          highlighted = (finding_index == cursor_index)
          mark = finding.accepted ? "[x]" : "[ ]"
          line = "  #{mark} ##{finding.id} #{finding.title}"
          line += "  — #{finding.justification}" if finding.justification

          attrs = Curses.color_pair(Palette::PAIR_DEFAULT)
          attrs |= Curses::A_REVERSE if highlighted
          with_attr(attrs) { put(screen_row, 0, line) }
        end

        # Status line clears after each draw — the buffered flash is a
        # one-shot so the next subprocess action gets a clean slate.
        def draw_status_line
          row = Curses.lines - 1
          Curses.setpos(row, 0)
          Curses.clrtoeol
          if @flash_message
            attrs = Curses.color_pair(Palette::PAIR_FLASH) | Curses::A_BOLD
            with_attr(attrs) { Curses.addstr(@flash_message.to_s) }
            @flash_message = nil
          else
            Curses.addstr("[space] toggle  [d] develop  [a] accept all  [r] reject all  [esc] back")
          end
        end

        def draw_centered_message(message, row)
          col = [ (Curses.cols - message.length) / 2, 0 ].max
          put(row, col, message)
        end

        def put(row, col, text)
          Curses.setpos(row, col)
          Curses.addstr(text.to_s)
        end

        def with_attr(attrs)
          Curses.attron(attrs)
          yield
        ensure
          Curses.attroff(attrs)
        end
      end
    end
  end
end
