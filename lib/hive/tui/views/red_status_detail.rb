require "lipgloss"
require "hive"
require "hive/agent_profiles"
require "hive/config"
require "hive/task"
require "hive/tui/styles"
require "hive/tui/text"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      module RedStatusDetail
        # Shared key list — referenced by both the footer and the
        # KeyMap hint flash. Single source so a key rename in one
        # surface cannot drift away from the other.
        ACTION_KEYS = [
          { footer: "[Enter] Recover",      hint: "press Enter to recover" },
          { footer: "[o] Open in agent",    hint: "o to open in agent" },
          { footer: "[Esc] back",           hint: "Esc / q to close" }
        ].freeze
        FOOTER = ACTION_KEYS.map { |k| k[:footer] }.join("   ").freeze
        AGENT_FALLBACK = "your project's development agent".freeze

        # Detect a `TaskAction#marker_summary`-style string (uppercase
        # marker name optionally followed by attr key=value pairs) that
        # leaked into diagnostic["summary"] from an older artifact. The
        # detail screen must never echo debug copy — fall back to the
        # plain-English placeholder instead. See plan Unit 1.
        MARKER_SUMMARY_PATTERN = /\A[A-Z][A-Z0-9_]+(?:\s+[a-z_]+=\S+)*\z/

        module_function

        def render(model)
          state = model.red_status_detail_state
          return "" if state.nil?

          row = state.row
          outer_width = [ model.cols.to_i - 2, 1 ].max
          bordered = model.cols.to_i >= 40
          inner_width = bordered ? [ outer_width - 2, 1 ].max : outer_width
          body_height = [ model.rows.to_i - 4, 1 ].max
          footer_line = Styles::HINT.render(truncate(FOOTER, inner_width))

          body_lines = []
          body_lines << Styles::HEADER.render(truncate("Task needs attention · #{safe(row.slug)}", inner_width))
          body_lines << ""
          body_lines << truncate("Project: #{safe(row.project_name)}", inner_width)
          body_lines << truncate("Stage: #{safe(row.stage)}", inner_width)
          body_lines.concat(wrapped("Why: #{summary_text(row)}", inner_width))
          body_lines << ""
          body_lines << Styles::HEADER.render(truncate("Actions", inner_width))
          # Unified affordance: [Enter] Recover is always shown
          # regardless of row.action_key. Rows with no automatic
          # recovery recipe (e.g., recover_execute / EXECUTE_STALE)
          # flash the Risk-#3 mitigation text and close the screen,
          # rather than hiding the affordance and stranding the
          # operator on a "now what?" view.
          body_lines << truncate("[Enter] Recover — re-run hive's automated recovery for this task", inner_width)
          body_lines << truncate("[o]     Open in agent — launch #{state.agent_label || AGENT_FALLBACK} in the task worktree", inner_width)

          # Reserve the footer line outside the body_height trim so a
          # short terminal or a long wrapped "Why" block can never
          # clip the only on-screen reference for the action keys.
          inner_body_height = [ body_height - 2, 1 ].max
          visible = body_lines.first(inner_body_height)
          visible << ""
          visible << footer_line
          body = Lipgloss.join_vertical(Lipgloss::TOP, *visible)
          return body unless bordered

          Styles::PANE_FOCUSED_BORDER.width(inner_width).render(body)
        end

        def summary_text(row)
          diagnostic = row.diagnostic || {}
          summary = safe(diagnostic["summary"]).strip
          return missing_summary_fallback if summary.empty?
          # marker_summary leaked from TaskAction: strip and use the
          # plain-English fallback rather than dump debug copy.
          return missing_summary_fallback if summary.match?(MARKER_SUMMARY_PATTERN)

          summary
        end

        def missing_summary_fallback
          "Hive does not have a diagnosis yet — try Open in agent to inspect."
        end

        # Called by `Update.apply_open_red_status_detail` so the resolved
        # label is cached on RedStatusDetailState at open time — render
        # stays a pure projection and the per-frame Hive::Config.load
        # cost only fires once per screen open. Plan Risk #4.
        def resolve_agent_label(row)
          task = Hive::Task.new(row.folder.to_s)
          cfg = Hive::Config.load(task.project_root)
          agent_name = cfg.dig("execute", "agent") || "claude"
          profile = Hive::AgentProfiles.lookup(agent_name, cfg: cfg)
          basename = File.basename(profile.bin.to_s)
          basename.empty? ? AGENT_FALLBACK : basename
        rescue Hive::ConfigError, Hive::AgentProfiles::UnknownAgent,
               Hive::AgentError, Hive::InvalidTaskPath, Psych::SyntaxError
          AGENT_FALLBACK
        end

        def wrapped(text, width)
          text = safe(text)
          return [ "" ] if text.empty?

          text.lines.flat_map { |line| wrap_line(line.chomp, width) }
        end

        def wrap_line(line, width)
          return [ "" ] if line.empty?
          return [ truncate(line, width) ] if width <= 8

          words = line.split(/\s+/)
          rows = []
          current = +""
          words.each do |word|
            if current.empty?
              current = word
            elsif "#{current} #{word}".length <= width
              current << " " << word
            else
              rows << truncate(current, width)
              current = word
            end
          end
          rows << truncate(current, width) unless current.empty?
          rows
        end

        def safe(value)
          Hive::Tui::Text.sanitize(value.to_s)
        end

        def truncate(string, width)
          Views::Format.truncate(string, width)
        end
      end
    end
  end
end
