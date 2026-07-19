require "json"

module Hive
  module Commands
    module ServiceInstaller
      # Shared command-side orchestration for daemon and bot service installs.
      # The platform installers own unit writes and service-manager calls; this
      # mixin owns their identical human summaries, JSON envelopes, and typed
      # failure translation. Consumers provide only four identity hooks.
      module ResultPresenter
        private

        def perform_service_install(installer)
          outcome = service_install_outcome(installer)
          unless @json
            installer.messages.each { |line| warn "hive: #{line}" }
            emit_install_success_summary(installer, outcome)
          end
          emit_install_outcome(installer, outcome)
        end

        def service_install_outcome(installer)
          installer.install!(autostart: true, force: @force)
        rescue Hive::Error
          raise
        rescue StandardError => error
          install_emit_exception_envelope(installer, error) if @json
          raise service_install_failure_error,
                "#{service_install_label} service install failed: #{error.class}: #{error.message}"
        end

        def emit_install_success_summary(installer, outcome)
          return if @json

          case outcome.kind
          when :written
            puts "hive #{service_install_label}: installed unit at #{installer.target_path}"
          when :upgraded
            message = "hive #{service_install_label}: upgraded unit at #{installer.target_path}"
            message += " (backup: #{outcome.backup_path})" if outcome.backup_path
            puts message
          when :unchanged
            puts "hive #{service_install_label}: unit already up to date at #{installer.target_path}"
          when :autostart_unavailable
            puts "hive #{service_install_label}: unit written at #{installer.target_path}; " \
                 "autostart not enabled on this host"
          when :unsupported, :drifted, :failed
            # Unsupported hosts are explained by installer.messages. Drift and
            # service-manager failures are raised by emit_install_outcome.
          end
        end

        def emit_install_outcome(installer, outcome)
          if @json
            if outcome.success?
              puts JSON.generate(install_envelope(installer, outcome))
            else
              install_emit_error_envelope(installer, outcome: outcome.wire_outcome)
            end
          end

          if outcome.drifted?
            message = "#{service_install_label} unit at #{installer.target_path} differs from the current template. " \
                      "Re-run with `hive #{service_install_label} install --force` to overwrite " \
                      "(a timestamped .bak will be saved)."
            raise service_install_drift_error, message
          elsif outcome.failed?
            raise service_install_failure_error,
                  "#{service_install_label} service install reported a failure; see messages above"
          end
        end

        def install_envelope(installer, outcome)
          {
            "schema" => service_install_schema,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(service_install_schema),
            "ok" => true,
            "outcome" => outcome.wire_outcome,
            "platform" => installer.envelope_platform,
            "target_path" => installer.target_path,
            "backup_path" => outcome.backup_path,
            "restarted" => outcome.restarted,
            "messages" => installer.messages.dup
          }
        end

        def install_emit_error_envelope(installer, outcome:)
          drifted = outcome == "drifted"
          error_class = drifted ? service_install_drift_error : service_install_failure_error
          exit_code = drifted ? Hive::ExitCodes::USAGE : Hive::ExitCodes::SOFTWARE
          message =
            if drifted
              "#{service_install_label} unit at #{installer.target_path} differs from the current " \
                "template; retry with --force."
            else
              "#{service_install_label} service install reported a failure; see messages"
            end
          puts JSON.generate(
            "schema" => service_install_schema,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(service_install_schema),
            "ok" => false,
            "error_class" => error_class.name.split("::").last,
            "error_kind" => outcome,
            "exit_code" => exit_code,
            "message" => message,
            "outcome" => outcome,
            "platform" => installer.envelope_platform,
            "target_path" => installer.target_path,
            "messages" => installer.messages.dup
          )
        end

        def install_emit_exception_envelope(installer, error)
          puts JSON.generate(
            "schema" => service_install_schema,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(service_install_schema),
            "ok" => false,
            "error_class" => service_install_failure_error.name.split("::").last,
            "error_kind" => "failed",
            "exit_code" => Hive::ExitCodes::SOFTWARE,
            "message" => "#{service_install_label} service install failed: #{error.class}: #{error.message}",
            "outcome" => "failed",
            "platform" => safe_install_platform(installer),
            "target_path" => safe_install_target_path(installer),
            "messages" => safe_install_messages(installer)
          )
        end

        def safe_install_platform(installer)
          installer.envelope_platform
        rescue StandardError
          "unsupported"
        end

        def safe_install_target_path(installer)
          installer.target_path
        rescue StandardError
          nil
        end

        def safe_install_messages(installer)
          installer.messages.dup
        rescue StandardError
          []
        end
      end
    end
  end
end
