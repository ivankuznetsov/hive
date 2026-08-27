require "hive"

module Hive
  module Commands
    # Shared `{ "ok": false, … }` error envelope for the Screenote connect and
    # disconnect commands. Both build their failure documents here so a future
    # field rename happens in one place; each command keeps its OWN emission
    # control flow (connect emits every failure through its single
    # emit_error_envelope owner, which guards re-emission locally;
    # disconnect emits unconditionally) and its own rescue around the `puts`.
    # This is the simpler Screenote-specific sibling of Hive::ErrorEnvelope.build,
    # which carries schema/schema_version fields the Screenote commands
    # deliberately do not emit.
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

      # Structured variant of {error_payload} for connect's
      # needs-project-selection outcome. The same `error_kind`/`exit_code`
      # fields every other `{"ok":false}` line carries let automation branch
      # uniformly: the distinct `needs_selection` kind tells "re-run with a
      # project selection" apart from an unrecoverable auth/network failure,
      # and the exit_code matches the GENERIC code bin/hive maps the raised
      # error to.
      def needs_selection_payload(projects)
        {
          "ok" => false,
          "service" => "screenote",
          "stage" => "needs_project_selection",
          "error_kind" => "needs_selection",
          "exit_code" => Hive::ExitCodes::GENERIC,
          "projects" => projects
        }
      end
    end
  end
end
