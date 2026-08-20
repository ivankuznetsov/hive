module AgentCliRuntime
  # Provider-side failures that a CLI reports on its event stream while still
  # exiting zero. Each profile owns the shape its own CLI emits. Extractors
  # return either the raw provider text, an ExtractedFailure, or nil when the
  # event carries no failure. Runtime.extract_provider_error normalizes and
  # redacts the result.
  module ErrorExtractors
    module_function

    # CLIs that name the failure with a dedicated event type. This is the same
    # set Hive scanned for inline before provider shape moved behind the
    # profile, so wiring a profile to DEFAULT preserves its behaviour.
    DEFAULT = lambda do |event|
      next nil unless event.is_a?(Hash)

      case event["type"]
      when "error", "turn.failed", "rate_limit_event"
        ErrorExtractors.message_from(event)
      when "result"
        if event["is_error"] == true || event["subtype"].to_s.start_with?("error")
          ErrorExtractors.message_from(event)
        end
      end
    end

    # pi keeps the envelope type ("message_start"/"message_end") and moves the
    # terminal state into stopReason. Provider refusals use
    # stopReason=error/errorMessage. A model that consumes its entire output
    # allowance uses stopReason=length and can exit zero without executing the
    # final write tool. Matching on type alone sees neither failure.
    PI = lambda do |event|
      next nil unless event.is_a?(Hash)

      message = event["message"].is_a?(Hash) ? event["message"] : event
      case message["stopReason"].to_s
      when "error"
        ErrorExtractors.message_from(message) || ErrorExtractors.message_from(event)
      when "length"
        ExtractedFailure.new(
          kind: :model_output_limit,
          message: "model response reached its maximum output tokens"
        )
      end
    end

    def message_from(event)
      return nil unless event.is_a?(Hash)

      candidates = [
        event["errorMessage"],
        event["message"],
        event.dig("error", "message"),
        event["error"]
      ]
      text = candidates.find { |value| value.is_a?(String) && !value.strip.empty? }
      text&.strip
    end
  end
end
