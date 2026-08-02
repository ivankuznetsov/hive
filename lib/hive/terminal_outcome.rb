require "hive/markers"
require "hive/workflow"

module Hive
  module TerminalOutcome
    MAX_FIRST_LINE_BYTES = 512
    MAX_OUTCOME_BYTES = Hive::Workflow::MAX_TERMINAL_OUTCOME_LENGTH
    OUTCOME_LINE = /\AOutcome: (?<outcome>[a-z0-9]+(?:-[a-z0-9]+)*)\z/

    Classification = Data.define(:kind, :outcome)
    Normalization = Data.define(:result, :changed)

    module_function

    def classify(path, outcomes)
      line = read_first_line(path)
      return line if line.is_a?(Classification)

      utf8 = line.dup.force_encoding(Encoding::UTF_8)
      return invalid("invalid-utf8") unless utf8.valid_encoding?

      match = OUTCOME_LINE.match(utf8)
      return invalid("malformed") unless match

      outcome = match[:outcome]
      return invalid("overlong") if outcome.bytesize > MAX_OUTCOME_BYTES
      return Classification.new(kind: :complete, outcome: outcome) if outcomes.complete.include?(outcome)
      return Classification.new(kind: :blocked, outcome: outcome) if outcomes.blocked.include?(outcome)

      invalid(outcome)
    end

    def normalize(task, result)
      stage = task.workflow.stage_named(task.stage_name)
      outcomes = stage&.terminal_outcomes
      return Normalization.new(result: result, changed: false) unless outcomes
      return Normalization.new(result: result, changed: false) unless stage.equal?(task.workflow.stages.last)
      return Normalization.new(result: result, changed: false) unless stage.kind == :agent
      return Normalization.new(result: result, changed: false) unless Hive::Markers.current(task.state_file).name == :complete

      classification = classify(task.state_file, outcomes)
      return Normalization.new(result: result, changed: false) if classification.kind == :complete

      reason = classification.kind == :blocked ? "terminal_outcome_blocked" : "terminal_outcome_invalid"
      Hive::Markers.set(
        task.state_file, :error,
        reason: reason, outcome: classification.outcome
      )
      normalized = result.is_a?(Hash) ? result.merge(commit: "error", status: :error) :
                   { commit: "error", status: :error }
      Normalization.new(result: normalized, changed: true)
    end

    def read_first_line(path)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)

      File.open(path, flags) do |io|
        opened = io.stat
        current = File.lstat(path)
        unless opened.file? && !current.symlink? &&
               opened.dev == current.dev && opened.ino == current.ino
          return invalid("non-regular")
        end

        window = io.read(MAX_FIRST_LINE_BYTES + 1).to_s.b
        newline = window.index("\n")
        return invalid("overlong") if newline.nil? && window.bytesize > MAX_FIRST_LINE_BYTES
        return invalid("overlong") if newline && newline > MAX_FIRST_LINE_BYTES

        newline ? window.byteslice(0, newline) : window
      end
    rescue Errno::ENOENT
      invalid("missing")
    rescue Errno::ELOOP
      invalid("non-regular")
    rescue SystemCallError, IOError
      invalid("unreadable")
    end
    private_class_method :read_first_line

    def invalid(detail)
      Classification.new(kind: :invalid, outcome: detail)
    end
    private_class_method :invalid
  end
end
