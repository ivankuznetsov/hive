require "json"
require "hive/config"

module Hive
  module Commands
    # `hive forget NAME [--json]` — remove the entry whose `name` matches
    # NAME from the global registry (~/Dev/hive/config.yml). The
    # project's `.hive-state` directory on disk is not touched; the
    # registry and the on-disk state are independent.
    #
    # Symmetric inverse of `hive init`. An unknown name is a USAGE
    # error (64), mirroring `hive metrics --project NAME` for
    # consistency across the CLI surface.
    class Forget
      class UsageError < Hive::Error
        attr_reader :error_kind

        def initialize(message, error_kind:)
          super(message)
          @error_kind = error_kind
        end

        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def initialize(name, json: false)
        @name = name
        @json = json
      end

      def call
        @stdout_written = false
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json && !@stdout_written
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json && !@stdout_written
        raise wrapped
      end

      def do_call
        if @name.nil? || @name.to_s.strip.empty?
          fail_usage!("hive forget: missing project NAME", kind: "unknown_project")
        end

        removed = Hive::Config.unregister_project(name: @name)
        if removed.nil?
          fail_usage!(
            "hive forget: no entry named #{@name.inspect} in #{Hive::Config.global_config_path}",
            kind: "unknown_project"
          )
        end

        if @json
          puts JSON.generate(success_payload(removed))
          @stdout_written = true
        else
          puts "removed #{removed['name']} (#{removed['path']})"
        end
      end

      def success_payload(removed)
        {
          "schema" => "hive-forget",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-forget"),
          "ok" => true,
          "name" => removed["name"],
          "path" => removed["path"],
          "hive_state_path" => removed["hive_state_path"] || File.join(removed["path"], ".hive-state")
        }
      end

      def fail_usage!(message, kind:)
        error = UsageError.new(message, error_kind: kind)
        if @json
          puts JSON.generate(
            "schema" => "hive-forget",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-forget"),
            "ok" => false,
            "error_kind" => kind,
            "exit_code" => Hive::ExitCodes::USAGE,
            "message" => message
          )
          @stdout_written = true
        else
          warn message
        end
        raise error
      end

      def emit_error_envelope(error)
        payload = {
          "schema" => "hive-forget",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-forget"),
          "ok" => false,
          "error_kind" => error_kind_for(error),
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        }
        puts JSON.generate(payload)
        @stdout_written = true
      rescue Errno::EPIPE, JSON::GeneratorError
        @stdout_written = true
      end

      def error_kind_for(error)
        case error
        when UsageError              then error.error_kind
        when Hive::ConfigError       then "config"
        when Hive::InternalError     then "internal"
        else                              "error"
        end
      end
    end
  end
end
