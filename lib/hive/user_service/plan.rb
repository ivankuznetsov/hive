module Hive
  class UserService
    Plan = Data.define(
      :operation,
      :action,
      :definition_fingerprint,
      :expected_observation,
      :status,
      :manager_observed,
      :autostart,
      :force
    ) do
      ACTIONS = {
        apply: %i[unsupported unsafe refuse_drift write replace noop],
        remove: %i[none remove]
      }.freeze

      def initialize(operation:, action:, definition_fingerprint:, expected_observation:,
                     status:, manager_observed: false, autostart: false, force: false)
        operation = operation.to_sym
        action = action.to_sym
        allowed_actions = ACTIONS[operation]
        raise ArgumentError, "unknown user service plan operation #{operation.inspect}" unless allowed_actions
        unless allowed_actions.include?(action)
          raise ArgumentError, "invalid #{operation} action #{action.inspect}"
        end
        unless status.is_a?(Status)
          raise ArgumentError, "user service plan status must be a Hive::UserService::Status"
        end
        unless String(expected_observation) == status.observation_key
          raise ArgumentError, "user service plan observation does not match its status"
        end

        super(
          operation: operation,
          action: action,
          definition_fingerprint: String(definition_fingerprint),
          expected_observation: String(expected_observation),
          status: status,
          manager_observed: !!manager_observed,
          autostart: !!autostart,
          force: !!force
        )
      end
    end
  end
end
