require "hive/markers"
require "hive/workflow"

module Hive
  module TerminalOutcome
    MAX_FIRST_LINE_BYTES = 512
    MAX_OUTCOME_BYTES = Hive::Workflow::MAX_TERMINAL_OUTCOME_LENGTH
    OUTCOME_PREFIX = "Outcome: ".freeze
    BLOCKED_REASON = "terminal_outcome_blocked".freeze
    INVALID_REASON = "terminal_outcome_invalid".freeze
    ERROR_REASONS = [ BLOCKED_REASON, INVALID_REASON ].freeze

    Classification = Data.define(:kind, :outcome)
    Normalization = Data.define(:result, :changed)

    module_function

    def classify(path, outcomes)
      line = read_first_line(path)
      return line if line.is_a?(Classification)

      utf8 = line.dup.force_encoding(Encoding::UTF_8)
      return invalid("invalid-utf8") unless utf8.valid_encoding?

      return invalid("malformed") unless utf8.start_with?(OUTCOME_PREFIX)

      outcome = utf8.delete_prefix(OUTCOME_PREFIX)
      unless Hive::Workflow::TERMINAL_OUTCOME_SAFE_SLUG.match?(outcome)
        return invalid("malformed")
      end
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

      marker = Hive::Markers.current(task.state_file)
      return Normalization.new(result: result, changed: false) unless [ :complete, :none ].include?(marker.name)

      classification = classify(task.state_file, outcomes)
      if marker.name == :complete && classification.kind == :complete
        return Normalization.new(result: result, changed: false)
      end

      blocked = marker.name == :complete && classification.kind == :blocked
      reason = blocked ? BLOCKED_REASON : INVALID_REASON
      outcome = if marker.name == :none && classification.kind != :invalid
        "missing-complete-marker"
      else
        classification.outcome
      end
      Hive::Markers.set(
        task.state_file, :error,
        reason: reason, outcome: outcome
      )
      normalized = if result.is_a?(Hash)
        result.merge(commit: "error", status: :error)
      else
        { commit: "error", status: :error }
      end
      Normalization.new(result: normalized, changed: true)
    end

    def semantic_error?(attrs)
      ERROR_REASONS.include?(error_reason(attrs))
    end

    def blocked_error?(attrs)
      error_reason(attrs) == BLOCKED_REASON
    end

    def read_first_line(path)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)

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

    def error_reason(attrs)
      return "" unless attrs.respond_to?(:[])

      (attrs["reason"] || attrs[:reason]).to_s
    end
    private_class_method :error_reason
  end
end
