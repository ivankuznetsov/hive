module Hive
  module Bot
    module BrainstormParser
      Question = Struct.new(:round, :n, :text, :answer, keyword_init: true) do
        def answered?
          !answer.nil?
        end
      end

      ROUND_RE = /\A##\s+Round\s+(\d+)\b/i
      QUESTION_RE = /\A###\s+Q(\d+)\.\s*(.*)\z/
      ANSWER_RE = /\A###\s+A(\d+)\.\s*\z/
      MARKER_RE = /\A<!--\s*[A-Z_]+(?:\s+[^<>]*?)?\s*-->\s*\z/

      module_function

      def parse(path)
        parse_text(File.exist?(path) ? File.read(path, encoding: "UTF-8") : "")
      end

      def parse_text(text)
        questions = []
        current_round = nil
        current = nil
        mode = nil

        normalize_newlines(text).each_line(chomp: true) do |line|
          if (match = ROUND_RE.match(line))
            finalize(questions, current)
            current = nil
            mode = nil
            current_round = match[1].to_i
            next
          end

          if (match = QUESTION_RE.match(line))
            finalize(questions, current)
            current = {
              round: current_round,
              n: match[1].to_i,
              question_lines: [ match[2] ],
              answer_lines: nil
            }
            mode = :question
            next
          end

          if (match = ANSWER_RE.match(line))
            if current && current[:n] == match[1].to_i
              current[:answer_lines] = []
              mode = :answer
            end
            next
          end

          case mode
          when :question
            current[:question_lines] << line if current
          when :answer
            current[:answer_lines] << line if current
          end
        end

        finalize(questions, current)
        questions.sort_by { |question| [ question.round || 0, question.n ] }
      end

      def next_unanswered_question(parsed)
        parsed.find { |question| question.answer.nil? }
      end

      def unanswered_questions(parsed)
        parsed.select { |question| question.answer.nil? }
      end

      def question_for(parsed, question_n)
        parsed.find { |question| question.n == question_n }
      end

      def finalize(out, current)
        return unless current

        out << Question.new(
          round: current[:round],
          n: current[:n],
          text: clean_body(current[:question_lines]),
          answer: clean_answer(current[:answer_lines])
        )
      end
      private_class_method :finalize

      def clean_body(lines)
        Array(lines).join("\n").strip
      end
      private_class_method :clean_body

      def clean_answer(lines)
        return nil if lines.nil?

        body_lines = Array(lines).dup
        body_lines.pop while (last = body_lines.last) && (last.strip.empty? || MARKER_RE.match?(last))
        body = body_lines.join("\n").strip
        body.empty? ? nil : body
      end
      private_class_method :clean_answer

      def normalize_newlines(text)
        text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      end
      private_class_method :normalize_newlines
    end
  end
end
