require "hive/commands/module/inspect"

module Hive
  module Commands
    class Module
      class Status < Inspect
        def call!
          statuses = if @name.empty?
            inspector.all(include_tombstones: true)
          else
            status = inspector.inspect(@name, include_tombstone: true)
            raise Hive::ConfigError, "module #{@name.inspect} is not installed and has no history" unless status
            [ status ]
          end
          payload = {
            "schema" => "hive-module-status",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-module-status"),
            "ok" => true, "modules" => statuses.map(&:to_h)
          }
          emit(payload, human_lines: statuses.flat_map { |status| human_lines(status) })
        end
      end
    end
  end
end
