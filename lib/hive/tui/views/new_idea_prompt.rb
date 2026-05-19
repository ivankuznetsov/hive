require "lipgloss"
require "set"
require "hive/tui/styles"

module Hive
  module Tui
    module Views
      # Pure view function: `Views::NewIdeaPrompt.render(model) → String`.
      # Single bottom-strip line shown in `:new_idea` mode while the user
      # types a task title. Mirrors `Views::FilterPrompt`'s shape but
      # carries a project-scope label so the operator sees which project
      # the resulting `hive new <project> "<title>"` will land in before
      # pressing Enter.
      #
      # Project resolution for the label:
      # - `model.new_idea_project_name` → explicit target chosen from the
      #   project picker opened by ★ All projects.
      # - `model.scope == 0` (★ All projects) → unresolved; the picker
      #   must choose a project before this prompt can submit.
      # - `model.scope == n` → the nth registered project.
      # - No registered projects → `(no projects)`; submission flashes an
      #   error in U6's BubbleModel handler instead of dispatching.
      module NewIdeaPrompt
        PROMPT_PREFIX = "New idea (project=".freeze

        module_function

        # Multi-line wrap renderer. The buffer stays a single logical
        # line (Enter still submits — `hive new` takes a title, not
        # multi-paragraph content), but visually wraps across as many
        # rows as needed so the operator can see everything they typed.
        #
        # Row 1: `<label><first buffer chunk>`
        # Row 2..N: `<spaces aligned to label width><buffer chunk>`
        # Cursor block at the end of the last chunk.
        #
        # Caps the visible buffer at `MAX_VISIBLE_ROWS` rows; if the
        # buffer overflows that, the EARLIEST chunks scroll off (slide
        # like the single-line variant) so the cursor stays in view.
        # This keeps the prompt from growing unbounded and pushing the
        # task panes off-screen on a tall paste.
        MAX_VISIBLE_ROWS = 6

        def render(model, width: model.cols.to_i)
          buffer = model.new_idea_buffer.to_s
          cursor = model.new_idea_cursor.to_i.clamp(0, buffer.length)
          label = "#{PROMPT_PREFIX}#{project_label(model)}): "
          # Available cells per row = width - 1 (cursor block) - 1
          # (right margin). Chunks are sized so `label-width padding +
          # chunk + cursor` always fits within `row_width`, keeping
          # continuation rows aligned to the same column as the first chunk.
          row_width = [ width - 2, 1 ].max
          suffix = attachment_suffix(model, width: width)
          suffix_width = suffix.to_s.length
          chunk_capacity = [ row_width - label.length - 1 - suffix_width, 1 ].max
          chunks, cursor_chunk_idx, cursor_offset = chunk_buffer_with_cursor(buffer, cursor, chunk_capacity)
          visible, visible_cursor_idx, first_visible_idx = visible_chunks_for_cursor(chunks, cursor_chunk_idx)
          render_rows(
            label,
            visible,
            visible_cursor_idx,
            cursor_offset,
            suffix: suffix,
            capacity: chunk_capacity,
            first_chunk_index: first_visible_idx,
            broken_ranges: broken_placeholder_ranges(buffer, model.new_idea_broken_labels)
          )
        end

        # Split `buffer` into chunks of `capacity` chars each. Always
        # returns at least one chunk (empty string) so the cursor has
        # somewhere to land.
        def chunk_buffer(buffer, capacity)
          return [ "" ] if buffer.empty?

          chunks = []
          offset = 0
          while offset < buffer.length
            chunks << buffer[offset, capacity].to_s
            offset += capacity
          end
          chunks
        end

        def chunk_buffer_with_cursor(buffer, cursor, capacity)
          chunks = chunk_buffer(buffer, capacity)
          cursor = cursor.to_i.clamp(0, buffer.length)
          cursor_chunk_idx, cursor_offset = cursor_position(buffer, cursor, capacity, chunks)
          [ chunks, cursor_chunk_idx, cursor_offset ]
        end

        def cursor_position(buffer, cursor, capacity, chunks)
          return [ 0, 0 ] if buffer.empty?
          return [ chunks.size - 1, chunks.last.length ] if cursor >= buffer.length

          [ cursor / capacity, cursor % capacity ]
        end

        def visible_chunks_for_cursor(chunks, cursor_chunk_idx)
          return [ chunks, cursor_chunk_idx, 0 ] if chunks.size <= MAX_VISIBLE_ROWS

          start = [ cursor_chunk_idx - MAX_VISIBLE_ROWS + 1, 0 ].max
          start = [ start, chunks.size - MAX_VISIBLE_ROWS ].min
          visible = chunks[start, MAX_VISIBLE_ROWS]
          [ visible, cursor_chunk_idx - start, start ]
        end

        # Row 1: styled label + chunk
        # Row 2..N: spaces aligned to label width + chunk
        # Cursor block at the logical cursor position.
        def render_rows(label, chunks, cursor_chunk_idx, cursor_offset, cursor: Styles::CURSOR_HIGHLIGHT.render(" "), suffix: nil, capacity: nil, first_chunk_index: 0, broken_ranges: [])
          padding = " " * label.length
          rows = chunks.each_with_index.map do |chunk, idx|
            prefix = idx.zero? ? Styles::HINT.render(label) : padding
            chunk_start = capacity ? (first_chunk_index + idx) * capacity : nil
            row = if idx == cursor_chunk_idx
              body = if chunk_start
                render_chunk_with_cursor(chunk, chunk_start, chunk_start + cursor_offset, cursor, broken_ranges)
              else
                before_cursor = chunk[0...cursor_offset].to_s
                after_cursor = chunk[cursor_offset..].to_s
                "#{before_cursor}#{cursor}#{after_cursor}"
              end
              "#{prefix}#{body}"
            elsif chunk_start
              "#{prefix}#{render_chunk_with_cursor(chunk, chunk_start, nil, cursor, broken_ranges)}"
            else
              "#{prefix}#{chunk}"
            end
            idx == chunks.size - 1 && suffix ? "#{row}#{Styles::HINT.render(suffix)}" : row
          end
          rows.join("\n")
        end

        def broken_placeholder_ranges(buffer, broken_labels)
          labels = Array(broken_labels).to_set
          return [] if labels.empty?

          ranges = []
          buffer.to_s.to_enum(:scan, /\[image(\d+)\]/).each do
            match = Regexp.last_match
            label = "image#{match[1].to_i}"
            ranges << [ match.begin(0), match.end(0) ] if labels.include?(label)
          end
          ranges
        end

        def render_chunk_with_cursor(chunk, chunk_start, cursor_absolute, cursor, broken_ranges)
          out = +""
          run = +""
          run_broken = nil

          chunk.each_char.with_index do |char, offset|
            absolute = chunk_start + offset
            if cursor_absolute == absolute
              out << render_segment(run, run_broken)
              run = +""
              run_broken = nil
              out << cursor
            end

            broken = broken_position?(absolute, broken_ranges)
            if run_broken.nil? || run_broken == broken
              run << char
              run_broken = broken
            else
              out << render_segment(run, run_broken)
              run = +char
              run_broken = broken
            end
          end

          out << render_segment(run, run_broken)
          out << cursor if cursor_absolute == chunk_start + chunk.length
          out
        end

        def render_segment(text, broken)
          return "" if text.empty?

          broken ? Styles::BROKEN_PLACEHOLDER.render(text) : text
        end

        def broken_position?(absolute, broken_ranges)
          broken_ranges.any? { |start_pos, end_pos| absolute >= start_pos && absolute < end_pos }
        end

        # Trailing badge appended to the prompt's last visual row when
        # at least one image is staged. Width threshold (30 cells)
        # suppresses the badge on very narrow terminals where it would
        # squeeze the prompt buffer below readable. The " · " separator
        # is a single-codepoint, fixed-width separator — emoji would
        # split unpredictably across terminals and lipgloss column math.
        def attachment_suffix(model, width:)
          count = model.new_idea_attachments.size
          return nil if count.zero?
          return nil if width.to_i < 30

          " · [#{count} #{count == 1 ? "image" : "images"}]"
        end

        # Resolve which project an idea would land in. Pure read of the
        # snapshot; never raises (falls through to "(no projects)").
      def project_label(model)
        name = resolve_project_name(model)
        if name.nil?
          projects = Array(model.snapshot&.projects)
          return "(choose project)" if model.scope.zero? && projects.any? { |p| p.error.nil? }

          return "(no projects)"
        end

        name
      end

      def resolve_project_name(model)
        snap = model.snapshot
        return nil if snap.nil? || snap.projects.empty?

        chosen = model.new_idea_project_name.to_s
        unless chosen.empty?
          project = snap.projects.find { |p| p.name == chosen }
          return project.name if project && project.error.nil?

          return nil
        end

        return nil if model.scope.zero?
        return nil unless model.scope.between?(1, snap.projects.size)

          project = snap.projects[model.scope - 1]
          # An explicit scope onto an unhealthy project also returns
          # nil — submit_new_idea then flashes "no projects" rather
          # than dispatching against a doomed directory. The TUI's
          # left pane still shows the project (with its name) so the
          # operator can navigate elsewhere.
          return nil if project.error

          project.name
        end
      end
    end
  end
end
