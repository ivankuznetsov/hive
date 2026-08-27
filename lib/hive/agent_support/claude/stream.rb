module Hive::AgentSupport::Claude::Stream
  MAX_DIAGNOSTIC_BYTES = 200

  class TokenMeter < Hive::AgentSupport::StreamMeter
    def initialize(*)
      super
      @completed = { input: 0, output: 0, cached: 0 }
      @turn = nil
    end

    protected

    def observe_increment(event, usage)
      return super unless event.is_a?(Hash) && event["type"] == "stream_event"

      if event.dig("event", "type") == "message_start"
        finish_turn
        @turn = usage_counts(usage)
      else
        @turn ||= { input: 0, output: 0, cached: 0 }
        usage_counts(usage).each { |key, count| @turn[key] = [ @turn[key], count ].max }
      end
      counts = @completed.dup
      @turn&.each { |key, count| counts[key] += count }
      @usage.merge!(counts)
      @total = counts.values_at(:input, :output).sum
    end

    def finish_turn
      @turn&.each { |key, count| @completed[key] += count }
    end
  end

  module_function

  def failure(event)
    return unless event.is_a?(Hash) && event["type"] == "result" &&
      event["subtype"] == "error_max_budget_usd"

    {
      origin: "budget_exhausted", subtype: event["subtype"],
      observed_cost_usd: finite_number(event["total_cost_usd"]),
      diagnostic: diagnostic(Array(event["errors"]).first),
      remedy: "raise_stage_budget"
    }.compact
  end

  def turn_started?(event) = stream_event?(event, "message_start")
  def turn_completed?(event) = stream_event?(event, "message_delta")
  def output_completed_event?(event) = event.is_a?(Hash)

  def write_tool_event?(event)
    return false unless event.is_a?(Hash)

    block = event.dig("event", "content_block")
    return true if tool_write?(block)

    message = event["message"]
    Array(message.is_a?(Hash) && message["content"]).any? { |item| tool_write?(item) }
  end

  def stream_event?(event, type)
    event.is_a?(Hash) && event["type"] == "stream_event" && event.dig("event", "type") == type
  end

  def tool_write?(item)
    item.is_a?(Hash) && item["type"] == "tool_use" && item["name"] == "Write"
  end

  def finite_number(value)
    number = Float(value)
    number if number.finite?
  rescue ArgumentError, TypeError
    nil
  end

  def diagnostic(value)
    text = value.to_s.strip
    text.byteslice(0, MAX_DIAGNOSTIC_BYTES).to_s.scrub unless text.empty?
  end
  private_class_method :stream_event?, :tool_write?, :finite_number, :diagnostic
end
