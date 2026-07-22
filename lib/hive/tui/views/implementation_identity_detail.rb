require "lipgloss"
require "hive/tui/text"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Read-only detail view for the generation-scoped implementation owner.
      # All data comes from Snapshot::Row; rendering never reads configuration
      # or task files and therefore cannot trigger legacy reconstruction.
      module ImplementationIdentityDetail
        TITLE = "Implementation ownership".freeze
        STAGES = %w[execute open_pr review.fix review.ci].freeze
        FOOTER = "I / q / Esc close".freeze

        module_function

        def render(model)
          state = model.implementation_identity_detail_state
          return "" unless state

          row = state.row
          identity = row.implementation_identity || {}
          width = [ model.cols.to_i - 4, 36 ].max
          lines = [
            TITLE,
            "",
            "Task: #{sanitize(row.slug)}",
            "Generation: #{identity.fetch('generation', 'pending')}",
            ""
          ]
          if identity["pending"]
            lines << "Execute ownership is pending; no implementation process has been captured."
          else
            lines.concat(stage_lines(identity.fetch("stages", {}), width))
          end
          lines << ""
          lines << FOOTER

          Lipgloss::Style.new
                          .border(Lipgloss::Border::NORMAL)
                          .padding(1, 2)
                          .width(width)
                          .render(lines.join("\n"))
        end

        def stage_lines(stages, width)
          STAGES.flat_map do |stage|
            entry = stages[stage] || { "status" => "pending" }
            owner = if entry["provider"] && entry["model"]
              "#{sanitize(entry['provider'])}/#{sanitize(entry['model'])}"
            else
              "—"
            end
            [
              Format.truncate("#{stage.ljust(11)} #{owner}", width),
              Format.truncate(
                "  effort=#{effort_label(entry)} source=#{sanitize(entry['source'] || '—')} " \
                "status=#{sanitize(entry['status'] || 'pending')}",
                width
              )
            ]
          end
        end

        def effort_label(entry)
          requested = sanitize(entry["requested_effort"] || "—")
          return requested if entry["effort_supported"] == true
          return "—" if requested == "—"

          "#{requested} (requested, not applied)"
        end

        def sanitize(value)
          Hive::Tui::Text.sanitize(value)
        end
      end
    end
  end
end
