require "hive/agent_support/stream_meter"
require "hive/implementation_identity"

module Hive::AgentSupport::Agy
  module Stream
    # The model appears in init even when the terminal usage has no model.
    # A model reported by a generation takes precedence over the opening selector.
    class ModelIdentity
      def observe(event)
        return unless event.is_a?(Hash)

        kind = event["event"]
        return unless %w[init step_update result].include?(kind)
        payload = event[kind]
        return unless payload.is_a?(Hash)

        id = payload["conversation_id"] || event["conversation_id"]
        return if @conversation_id && id && id != @conversation_id
        @conversation_id ||= id if kind == "init"
        return if kind == "step_update" && (!@conversation_id || id != @conversation_id)
        raw = payload["model"]
        return unless raw.is_a?(String) && raw.bytesize.between?(1, 256)
        model = Hive::AgentSupport::Agy.normalize_settings_model(raw)
        return unless model && Hive::ImplementationIdentity::MODEL_PATTERN.match?(model)
        return if %w[auto default inherit].include?(model.downcase)

        if kind == "init"
          @initial_model ||= model
        elsif kind == "result" || payload["step_type"] == "agent_response"
          @mixed ||= @served_model && @served_model != model
          @served_model = model
        end
      end

      def evidence_source = "provider_stream_event"

      def model
        @served_model || @initial_model unless @mixed
      end
    end

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
