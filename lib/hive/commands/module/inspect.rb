require "hive/commands/module/base"

module Hive
  module Commands
    class Module
      class Inspect < Base
        def initialize(name, **options)
          super(**{ yes: false, dry_run: false, receipt: nil }.merge(options))
          @name = name.to_s
        end

        def call!
          status = inspector.inspect(@name, include_tombstone: true)
          raise Hive::ConfigError, "module #{@name.inspect} is not installed and has no history" unless status
          payload = envelope(status.to_h)
          emit(payload, human_lines: human_lines(status))
        end

        private

        def envelope(status)
          {
            "schema" => "hive-module-status",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-module-status"),
            "ok" => true, "modules" => [ status ]
          }
        end

        def human_lines(status)
          [ "#{status['name']} state=#{status['lifecycle_state']} failure=#{status['failure_reason'] || '-'}" ]
        end

        def envelope_schema = "hive-module-status"
      end
    end
  end
end
