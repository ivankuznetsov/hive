require "hive"

module Hive
  module Commands
    # Shared `{ "ok": false, … }` error envelope for the Screenote connect and
    # disconnect commands. Both emit the identical 6-key failure document; the
    # builder lives here once so a future field rename happens in one place.
    # Each command keeps its OWN emission control flow (connect guards
    # re-emission via @error_emitted; disconnect emits unconditionally) and its
    # own rescue around the `puts`. This is the simpler Screenote-specific
    # sibling of Hive::ErrorEnvelope.build, which carries schema/schema_version
    # fields the Screenote commands deliberately do not emit.
    module ScreenoteEnvelope
      module_function

      def error_payload(error)
        {
          "ok" => false,
          "service" => "screenote",
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "error",
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        }
      end
    end
  end
end
