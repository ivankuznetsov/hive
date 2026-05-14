require "hive/lock"
require "hive/markers"
require "hive/bot/brainstorm_parser"

module Hive
  module Bot
    module BrainstormAnswerWriter
      module_function

      QUESTION_RE = /\A###\s+Q(\d+)\.\s*/
      ANSWER_RE = /\A###\s+A(\d+)\.\s*\z/
      ROUND_RE = /\A##\s+Round\s+\d+\b/i
      MARKER_RE = /\A<!--\s*[A-Z_]+(?:\s+[^<>]*?)?\s*-->\s*\z/

      def append!(brainstorm_path:, question_n:, answer_text:)
        task_folder = File.dirname(brainstorm_path)
        raise Hive::InvalidTaskPath, "task folder does not exist: #{task_folder}" unless Dir.exist?(task_folder)

        Hive::Lock.with_task_lock(task_folder, "bot" => "brainstorm_answer") do
          content = File.exist?(brainstorm_path) ? File.read(brainstorm_path, encoding: "UTF-8") : ""
          parsed = Hive::Bot::BrainstormParser.parse_text(content)
          return :question_not_found unless parsed.any? { |question| question.n == question_n }
          return :already_answered unless parsed.any? { |question| question.n == question_n && question.answer.nil? }

          lines = content.lines
          slot = find_empty_answer_slot(lines, question_n)
          return :question_not_found unless slot

          answer_lines = answer_body(answer_text, newline_for(content)).lines
          new_lines = lines[0..slot[:answer_line_index]] + answer_lines + lines[slot[:body_end_index]..].to_a
          Hive::Markers.write_atomic(brainstorm_path, new_lines.join)
          :written
        end
      end

      def find_empty_answer_slot(lines, question_n)
        lines.each_with_index do |line, idx|
          match = ANSWER_RE.match(line.chomp)
          next unless match && match[1].to_i == question_n

          body_end = idx + 1
          body = []
          while body_end < lines.length && !block_boundary?(lines[body_end])
            body << lines[body_end]
            body_end += 1
          end
          next unless body.join.strip.empty?

          return { answer_line_index: idx, body_end_index: body_end }
        end
        nil
      end
      private_class_method :find_empty_answer_slot

      def block_boundary?(line)
        stripped = line.chomp
        QUESTION_RE.match?(stripped) || ROUND_RE.match?(stripped) || MARKER_RE.match?(stripped)
      end
      private_class_method :block_boundary?

      def answer_body(answer_text, newline)
        text = answer_text.to_s.rstrip
        text.empty? ? newline : "#{text}#{newline}"
      end
      private_class_method :answer_body

      def newline_for(content)
        content.include?("\r\n") ? "\r\n" : "\n"
      end
      private_class_method :newline_for
    end
  end
end
