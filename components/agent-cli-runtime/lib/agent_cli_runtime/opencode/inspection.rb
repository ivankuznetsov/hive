module AgentCliRuntime
  module OpenCode
    module Inspection
      module_function

      def compile(prepared, parsed_run)
        unless prepared.is_a?(PreparedInvocation)
          raise ArgumentError,
                "prepared must be an AgentCliRuntime::PreparedInvocation"
        end
        unless parsed_run.is_a?(ParsedRun)
          raise ArgumentError, "parsed_run must be an AgentCliRuntime::ParsedRun"
        end
        unless prepared.invocation.provider == :opencode
          raise ConfigurationError,
                "sanitized export inspection requires an OpenCode invocation"
        end

        InspectionCommand.new(
          argv: [
            prepared.executable, "export", parsed_run.session_id, "--sanitize"
          ],
          stdin_data: nil,
          environment: prepared.environment,
          credential_environment_keys: prepared.credential_environment_keys,
          session_id: parsed_run.session_id,
          message_id: parsed_run.terminal_message_id
        )
      end
    end
  end
end
