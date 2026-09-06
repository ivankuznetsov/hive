# frozen_string_literal: true

# Frozen compatibility fixture for the brainstorm grammar immediately before
# hive-suggestion:v1 existed. It intentionally knows nothing about advisory
# envelopes: downgrade cleanup must make its answer view match an artifact that
# never contained suggestions.
module PreFeatureBrainstormParser
  Question = Struct.new(:round, :n, :text, :answer, keyword_init: true) do
    def answered? = !answer.nil?
  end

  ROUND_RE = /\A##\s+Round\s+([1-9]\d*)\b/i
  QUESTION_RE = /\A###\s+Q([1-9]\d*)\.\s*(.*)\z/
  ANSWER_RE = /\A###\s+A([1-9]\d*)\.\s*(?:<!-- hive-answer:v1 -->)?\s*\z/
  MARKER_RE = /\A<!--\s*[A-Z_]+(?:\s+[^<>]*?)?\s*-->\s*\z/

  module_function

  def parse_text(text)
    questions = []
    current_round = nil
    current = nil
    mode = nil

    text.to_s.gsub("\r\n", "\n").gsub("\r", "\n").each_line(chomp: true) do |line|
      if (match = ROUND_RE.match(line))
        finalize(questions, current)
        current = nil
        mode = nil
        current_round = match[1].to_i
      elsif (match = QUESTION_RE.match(line))
        finalize(questions, current)
        current = {
          round: current_round, n: match[1].to_i,
          question_lines: [ match[2] ], answer_lines: nil
        }
        mode = :question
      elsif ANSWER_RE.match?(line)
        if current && current[:answer_lines].nil?
          current[:answer_lines] = []
          mode = :answer
        end
      elsif !MARKER_RE.match?(line)
        current[:question_lines] << line if current && mode == :question
        current[:answer_lines] << line if current && mode == :answer
      end
    end

    finalize(questions, current)
    questions
  end

  def finalize(out, current)
    return unless current

    answer = if current[:answer_lines]
      body = current[:answer_lines].dup
      body.pop while body.last&.strip&.empty?
      body = body.join("\n").strip
      body unless body.empty?
    end
    out << Question.new(
      round: current[:round], n: current[:n],
      text: current[:question_lines].join("\n").strip,
      answer: answer
    )
  end
  private_class_method :finalize
end
