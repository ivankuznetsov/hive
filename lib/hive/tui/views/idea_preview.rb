require "hive/tui/styles"
require "hive/tui/views/format"

module Hive
  module Tui
    module Views
      # Bottom-strip preview for a task's source idea.md original_text.
      # Read-only: KeyMap routes every key in :idea_preview mode back
      # to grid; this view only renders the captured model fields.
      module IdeaPreview
        DISMISS_HINT = "press any key to dismiss".freeze
        MAX_VISIBLE_ROWS = 6

        module_function

        def render(model, width: model.cols.to_i)
          usable = [ width.to_i, 1 ].max
          rows = [
            Styles::HINT.render(truncate("Idea for #{model.idea_preview_slug}:", usable)),
            *body_rows(model.idea_preview_text.to_s, usable),
            Styles::HINT.render(truncate(DISMISS_HINT, usable))
          ]
          rows.join("\n")
        end

        def body_rows(text, width)
          return [] if text.empty?

          wrap_text(text, width).first(MAX_VISIBLE_ROWS).map { |line| truncate(line, width) }
        end

        # Intentional local copy of NewIdeaPrompt's simple chunking shape.
        # NewIdeaPrompt's helper is cursor-aware and attachment-aware;
        # extracting it would widen this read-only view change.
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

        def wrap_text(text, width)
          capacity = [ width.to_i, 1 ].max
          text.each_line(chomp: true).flat_map do |line|
            chunk_buffer(line, capacity)
          end
        end

        def truncate(line, width)
          Views::Format.truncate(line, width.to_i)
        end
      end
    end
  end
end
