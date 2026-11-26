require "hive/agent_support/stream_meter"

module Hive::AgentSupport::Agy
  module Stream
    class TokenMeter < Hive::AgentSupport::StreamMeter
      def terminal?(event)
        event.is_a?(Hash) && event["event"] == "result"
      end
    end

    module_function

    def turn_started?(_event) = false
    def write_tool_event?(_event) = false
    def output_completed_event?(event) = event.is_a?(Hash)

    def turn_completed?(event)
      event.is_a?(Hash) &&
        event["event"] == "step_update" &&
        event.dig("step_update", "step_type") == "agent_response" &&
        event.dig("step_update", "state") == "DONE"
    end
  end
end
