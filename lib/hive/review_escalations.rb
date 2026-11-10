module Hive
  # Operator Q/A blocks in `reviews/escalations-NN.md`. Triage writes each
  # open decision as `### Q<n>.` followed by an empty `### A<n>.` block, and
  # the operator answers by filling that block. The review runner (which
  # feeds answers to the next fix pass or triage) and the recovery predicates
  # (which decide whether operator input exists) share this one parser so
  # "answered" means the same thing on every surface.
  module ReviewEscalations
    QUESTION = /^\s*###\s+Q(\d+)\.\s*(.*?)\s*$/
    ANSWER = /^\s*###\s+A(\d+)\.\s*$/

    module_function

    def path(folder, pass)
      File.join(folder.to_s, "reviews", "escalations-#{format('%02d', pass.to_i)}.md")
    end

    # Returns `{ number:, question:, body:, answer: }` hashes in file order,
    # or [] when the file is missing or unreadable.
    def questions(path)
      return [] unless File.exist?(path)

      questions = []
      current = nil
      mode = nil

      File.readlines(path).each do |line|
        if (match = QUESTION.match(line))
          questions << current if current
          current = {
            number: match[1].to_i,
            question: match[2].strip,
            body: +"",
            answer: +""
          }
          mode = :body
        elsif current && (match = ANSWER.match(line)) && match[1].to_i == current[:number]
          mode = :answer
        elsif current && mode
          current[mode] << line
        end
      end

      questions << current if current
      questions
    rescue SystemCallError, IOError
      []
    end

    def answered?(question)
      !question.fetch(:answer).strip.empty?
    end
  end
end
