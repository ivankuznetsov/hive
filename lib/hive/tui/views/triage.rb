require "lipgloss"
require "hive/tui/styles"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::Triage.render(model) → String`.
      # Mirrors `Render::Triage#draw` content layout — header (review
      # filename + slug), severity-grouped findings list with checkbox
      # state and cursor highlight, footer keystroke hint.
      #
      # Reads `model.triage_state` (Hive::Tui::TriageState). Returns
      # empty string if no triage state — Update guarantees this only
      # gets called when `model.mode == :triage`, so a nil triage_state
      # would be a programmer error; we render empty rather than raise
      # so a transient race during mode-flip doesn't crash the loop.
      module Triage
        SEVERITY_ORDER = %w[high medium low nit].freeze

        FOOTER_HINT = "[space] toggle  [d] develop  [a] accept all  [r] reject all  [esc] back".freeze

        module_function

        def render(model)
          state = model.triage_state
          return "" if state.nil?

          sections = []
          sections << header_line(state)
          sections << ""

          if state.findings.empty?
            sections << centered_message(model, "(no findings in this review file)")
          else
            sections.concat(grouped_findings_lines(state))
          end

          sections << ""
          sections << status_line(model)
          Lipgloss.join_vertical(Lipgloss::TOP, *sections.compact)
        end

        # ---- Sections ----

        def header_line(state)
          basename = state.review_path ? File.basename(state.review_path) : "(no review file)"
          line = "#{basename} — #{state.slug}"
          Styles::HEADER.render(line)
        end

        def grouped_findings_lines(state)
          out = []
          grouped = group_by_severity(state.findings)
          SEVERITY_ORDER.each do |severity|
            section = grouped[severity]
            next if section.nil? || section.empty?

            out << Styles::HEADER.render("## #{severity.capitalize}")
            section.each do |entry|
              out << finding_line(entry[:finding], entry[:index], state.cursor)
            end
            out << ""
          end

          # Surface findings whose severity isn't in SEVERITY_ORDER
          # under "## Other" so a malformed reviewer file still shows
          # every row instead of dropping silently — same contract as
          # the curses renderer.
          others = state.findings.each_with_index.reject { |f, _| SEVERITY_ORDER.include?(f.severity) }
          unless others.empty?
            out << Styles::HEADER.render("## Other")
            others.each { |finding, idx| out << finding_line(finding, idx, state.cursor) }
          end
          out
        end

        def group_by_severity(findings)
          grouped = Hash.new { |h, k| h[k] = [] }
          findings.each_with_index do |f, idx|
            grouped[f.severity] << { finding: f, index: idx }
          end
          grouped
        end

        def finding_line(finding, finding_index, cursor_index)
          highlighted = (finding_index == cursor_index)
          mark = finding.accepted ? "[x]" : "[ ]"
          line = "  #{mark} ##{finding.id} #{finding.title}"
          line += "  — #{finding.justification}" if finding.justification
          highlighted ? Styles::CURSOR_HIGHLIGHT.render(line) : line
        end

        def centered_message(model, message)
          width = [ model.cols.to_i, message.length ].max
          Lipgloss::Style.new.width(width).align(Lipgloss::CENTER).render(message)
        end

        # Status-line flash (one-shot) takes precedence over the hint.
        # The flash decay contract is the same as the grid's: Model
        # owns flash + flash_set_at, view consults flash_active?.
        def status_line(model)
          if model.flash_active?
            Styles::FLASH.render(model.flash.to_s)
          else
            Styles::HINT.render(FOOTER_HINT)
          end
        end
      end
    end
  end
end
