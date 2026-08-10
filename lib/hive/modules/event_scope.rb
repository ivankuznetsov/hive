require "hive/module_package/manifest"

module Hive
  module Modules
    # Install-time setup occurrences reuse the reviewed project.registered
    # vocabulary, but are intentionally scoped to the generation and hooks
    # activated by that install receipt. Ordinary project events remain broad.
    module EventScope
      module_function

      def matches?(event:, selection:, hook:)
        return true unless event.dig("source", "type") == "module_install"

        payload = event.fetch("payload")
        validate_setup_payload!(payload)
        active = selection.fetch("active")
        payload.fetch("target_module") == selection.fetch("name") &&
          payload.fetch("target_generation") == active.fetch("source_commit") &&
          payload.fetch("target_configuration_digest") == active.fetch("configuration_digest") &&
          payload.fetch("target_hooks").include?(hook.fetch("id"))
      end

      def validate_setup_payload!(payload)
        unless payload.is_a?(Hash) &&
               Hive::ModulePackage::Manifest::NAME.match?(payload["target_module"].to_s) &&
               Hive::ModulePackage::Manifest::REVISION.match?(payload["target_generation"].to_s) &&
               Hive::ModulePackage::Manifest::SHA256.match?(payload["target_configuration_digest"].to_s) &&
               Hive::ModulePackage::Manifest::SHA256.match?(payload["install_receipt_digest"].to_s) &&
               payload["target_hooks"].is_a?(Array) &&
               payload["target_hooks"].uniq == payload["target_hooks"] &&
               payload["target_hooks"].all? do |id|
                 Hive::ModulePackage::Manifest::NAME.match?(id.to_s)
               end
          raise Hive::ConfigError, "module install setup event scope is malformed"
        end
        true
      end
    end
  end
end
