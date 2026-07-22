require "hive/commands/module/base"

module Hive
  module Commands
    class Module
      class List < Base
        def initialize(**options)
          super(**{ yes: false, dry_run: false, receipt: nil }.merge(options))
        end

        def call!
          rows = inspector.all.map(&:to_h)
          payload = {
            "schema" => "hive-module-list",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-module-list"),
            "ok" => true, "modules" => rows
          }
          emit(payload, human_lines: rows.map { |item| human_row(item) })
        end

        private

        def human_row(row)
          active = row["active"] || row["previous"] || {}
          "#{row.fetch('name')} state=#{row.fetch('lifecycle_state')} version=#{active['version'] || '-'}"
        end

        def envelope_schema = "hive-module-list"
      end
    end
  end
end
