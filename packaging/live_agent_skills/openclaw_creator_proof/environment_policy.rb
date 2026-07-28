module HiveLiveAgentProof
  module OpenClawCreatorProof
    class EnvironmentPolicy
      def initialize(model:, credential:, base_environment:)
        @model = model.to_s
        @credential = credential.to_s
        @base_environment = base_environment.to_h.transform_keys(&:to_s)
      end

      def provider
        if @model.empty?
          raise Failure.new(
            phase: "preflight",
            reason: "missing_model",
            detail: "HIVE_LIVE_MODEL is required"
          )
        end
        provider_name, routed_model = @model.split("/", 2)
        credential_environment = PROVIDER_CREDENTIAL_ENV[provider_name]
        unless credential_environment && !routed_model.to_s.empty?
          raise Failure.new(
            phase: "preflight",
            reason: "unsupported_provider",
            detail: "HIVE_LIVE_MODEL must begin with openai/ or openrouter/"
          )
        end

        {
          "name" => provider_name,
          "model" => @model,
          "credential_environment" => credential_environment
        }
      end

      def child_environment(additions = {})
        environment = sanitized_environment
        additions.each do |name, value|
          name = name.to_s
          next if PROVIDER_CREDENTIAL_ENV.value?(name) ||
                  name == "HIVE_LIVE_PROVIDER_CREDENTIAL"

          environment[name] = value.to_s
        end
        environment[provider.fetch("credential_environment")] = @credential
        environment
      end

      def sanitized_environment
        PASSTHROUGH_ENV.each_with_object({}) do |name, selected|
          value = @base_environment[name]
          selected[name] = value unless value.nil?
        end
      end
    end
  end
end
