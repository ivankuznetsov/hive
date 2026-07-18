module Hive
  module Patrol
    module ReviewErrorDetails
      module_function

      def from_agent_result(result)
        exhaustion = result.is_a?(Hash) ? result[:resource_exhaustion] : nil
        return {} unless exhaustion.is_a?(Hash)

        {
          "details" => {
            "resource_exhaustion" => {
              "reason" => exhaustion[:reason].to_s,
              "limit" => exhaustion[:limit].to_i,
              "observed" => exhaustion[:observed].to_i
            }
          }
        }
      end
    end
  end
end
