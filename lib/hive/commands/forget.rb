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
    # consistency across the CLI surface. The empty-NAME case
    # (positional missing) emits a distinct `missing_name` error_kind
    # so agent retry wrappers can distinguish a typo against a real
    # registry from a missing argv entirely.
    class Forget
      include Hive::Schemas::EnvelopeEmitter

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
        call_with_envelope { do_call }
      end

      def envelope_schema
        "hive-forget"
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      def do_call
        if @name.nil? || @name.to_s.strip.empty?
          fail_usage!(
            "hive forget: missing project NAME",
            kind: Hive::Schemas::ForgetErrorKind::MISSING_NAME
          )
        end

        removed = Hive::Config.unregister_project(name: @name)
        if removed.nil?
          fail_usage!(
            "hive forget: no entry named #{@name.inspect} in #{Hive::Config.global_config_path}",
            kind: Hive::Schemas::ForgetErrorKind::UNKNOWN_PROJECT
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
        # Schema describes `path` and `hive_state_path` as "Absolute path".
        # The raw registry row may carry a relative or `~`-prefixed string
        # (hand-edited config.yml, or pre-normaliser entries). Run both
        # through File.expand_path here so the JSON envelope matches the
        # documented contract regardless of how the row got into the file.
        #
        # `name` is also stringified: `unregister_project` matches via
        # `to_s.==.to_s` so a hand-edited `name: 42` (Integer) is reachable
        # from the CLI's String argv. Without `.to_s` here, that drop would
        # leak an Integer into the envelope, violating the schema's
        # `"name": { "type": "string" }` contract.
        abs_path = File.expand_path(removed["path"].to_s)
        hive_state = removed["hive_state_path"] ? File.expand_path(removed["hive_state_path"]) : File.join(abs_path, ".hive-state")
        {
          "schema" => "hive-forget",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-forget"),
          "ok" => true,
          "name" => removed["name"].to_s,
          "path" => abs_path,
          "hive_state_path" => hive_state
        }
      end

      def fail_usage!(message, kind:)
        error = UsageError.new(message, error_kind: kind)
        if @json
          emit_envelope(error)
        else
          warn message
        end
        raise error
      end

      def error_kind_for(error)
        case error
        when UsageError              then error.error_kind
        when Hive::ConfigError       then Hive::Schemas::ForgetErrorKind::CONFIG
        when Hive::InternalError     then Hive::Schemas::ForgetErrorKind::INTERNAL
        else                              Hive::Schemas::ForgetErrorKind::INTERNAL
        end
      end
    end
  end
end
