require "hive/commands/module/base"

module Hive
  module Commands
    class Module
      class List < Base
        def initialize(**options)
          super(**{ yes: false, dry_run: false, receipt: nil }.merge(options))
        end

        def call!
          rows = store.selections.map { |selection| row(selection) }
          payload = {
            "schema" => "hive-module-list",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-module-list"),
            "ok" => true, "modules" => rows
          }
          emit(payload, human_lines: rows.map { |item| human_row(item) })
        end

        private

        def row(selection)
          active = selection.fetch("active")
          configuration = store.configuration(selection.fetch("name"), active.fetch("configuration_digest"))
          {
            "name" => selection.fetch("name"), "installed" => selection.fetch("installed"),
            "enabled" => selection.fetch("enabled"), "epoch" => selection.fetch("epoch"),
            "version" => active.fetch("version"), "catalog_commit" => active.fetch("catalog_commit"),
            "source_commit" => active.fetch("source_commit"), "manifest_digest" => active.fetch("manifest_digest"),
            "configuration_digest" => active.fetch("configuration_digest"),
            "permission_digest" => configuration.data.fetch("permission_digest"),
            "hooks" => configuration.hooks, "settings" => configuration.settings,
            "grants" => configuration.grants
          }
        end

        def human_row(row)
          "#{row.fetch('name')} version=#{row.fetch('version')} enabled=#{row.fetch('enabled')} source_commit=#{row.fetch('source_commit')}"
        end

        def envelope_schema = "hive-module-list"
      end
    end
  end
end
