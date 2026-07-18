require "hive/implementation_identity"

module Hive
  module ImplementationIdentity
    module UtilityModels
      REGISTRY = {
        claude: { model: "sonnet", pin_model: true }.freeze,
        codex: { model: "gpt-5.6-terra", pin_model: true }.freeze,
        pi: { model: nil, pin_model: false }.freeze,
        grok: { model: nil, pin_model: false }.freeze
      }.freeze

      module_function

      def resolve(provider)
        value = REGISTRY[provider.to_sym]
        raise ResolutionError, "no open-PR utility model policy for provider #{provider.inspect}" unless value

        value.dup
      end
    end
  end
end
