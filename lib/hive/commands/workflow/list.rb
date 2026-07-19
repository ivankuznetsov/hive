require "json"
require "hive/commands/workflow/base"
require "hive/workflows/descriptor_parser"
require "hive/workflows/registry"

module Hive
  module Commands
    class Workflow
      class List < Base
        SCHEMA = "hive-workflow-list".freeze

        def initialize(project_root:, json: false, stdout: $stdout, environment: ENV)
          super(project_root: project_root, json: json, stdout: stdout)
          @environment = environment
        end

        def call!
          managed = managed_rows
          rows = built_in_rows + authored_rows + managed + retained_rows(managed)
          rows.sort_by! { |row| [ row.fetch("name"), row.fetch("origin"), row["source_commit"].to_s ] }
          payload = {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "workflows" => rows
          }
          emit(payload, human_lines: rows.map { |row| human_row(row) })
        end

        private

        def built_in_rows
          Hive::Workflows::Registry::WORKFLOWS.keys.map do |name|
            row(name, "built_in")
          end
        end

        def authored_rows
          Dir.glob(File.join(store.workflows_dir, "*.yml")).sort.map do |path|
            workflow = Hive::Workflows::DescriptorParser.parse_file(path)
            row(workflow.id, "authored")
          rescue Hive::ConfigError
            row(File.basename(path, ".yml"), "authored", integrity: "malformed")
          end
        end

        def managed_rows
          return [] unless File.directory?(store.workflows_dir)

          Dir.glob(File.join(store.workflows_dir, "*", Hive::WorkflowPackage::ManagedStore::LOCK_FILE)).sort.map do |path|
            name = File.basename(File.dirname(path))
            lock = store.selected(name, cfg: project_config)
            result = store.verify_generation(name, lock.fetch("source_commit"), lock.fetch("manifest_digest"))
            configuration = store.configuration(
              name, lock.fetch("configuration_digest"), cfg: project_config
            )
            details = result.valid? ? configuration_details(configuration, result.manifest) : {}
            row(
              name, "managed", selection: "selected",
              integrity: result.valid? ? "verified" : "tampered",
              catalog_visibility: "unknown_offline",
              source_commit: lock.fetch("source_commit"), manifest_digest: lock.fetch("manifest_digest"),
              version: lock.fetch("version"), configuration_digest: lock.fetch("configuration_digest"),
              **details
            )
          rescue Hive::ConfigError, JSON::ParserError
            row(name, "managed", selection: "selected", integrity: "malformed",
                catalog_visibility: "unknown_offline")
          end
        end

        def retained_rows(managed)
          active_generations = managed.filter_map do |entry|
            [ entry["name"], entry["source_commit"] ] if entry["source_commit"]
          end.to_h { |identity| [ identity, true ] }
          active_configurations = managed.filter_map do |entry|
            next unless entry["source_commit"] && entry["configuration_digest"]

            [ entry["name"], entry["source_commit"], entry["configuration_digest"] ]
          end.to_h { |identity| [ identity, true ] }
          references = store.task_references.uniq do |reference|
            reference.values_at(:name, :commit, :digest, :configuration_digest)
          end
          references.filter_map do |reference|
            configuration_digest = reference[:configuration_digest]
            active = if configuration_digest
              active_configurations[[ reference.fetch(:name), reference.fetch(:commit), configuration_digest ]]
            else
              active_generations[[ reference.fetch(:name), reference.fetch(:commit) ]]
            end
            next if active

            result = store.verify_generation(reference.fetch(:name), reference.fetch(:commit), reference.fetch(:digest))
            row(reference.fetch(:name), "managed", selection: "retained",
                integrity: result.valid? ? "verified" : "tampered",
                catalog_visibility: "unknown_offline", source_commit: reference.fetch(:commit),
                manifest_digest: reference.fetch(:digest), configuration_digest: configuration_digest)
          end
        end

        def row(name, origin, selection: nil, integrity: nil, catalog_visibility: nil,
                source_commit: nil, manifest_digest: nil, version: nil,
                configuration_digest: nil, mappings: nil, optional_inputs: nil)
          result = {
            "name" => name.to_s,
            "origin" => origin,
            "selection" => selection,
            "integrity" => integrity,
            "catalog_visibility" => catalog_visibility,
            "version" => version,
            "source_commit" => source_commit,
            "manifest_digest" => manifest_digest
          }
          result["configuration_digest"] = configuration_digest if configuration_digest
          result["mappings"] = mappings unless mappings.nil?
          result["optional_inputs"] = optional_inputs unless optional_inputs.nil?
          result
        end

        def human_row(entry)
          dimensions = %w[
            origin selection integrity catalog_visibility version source_commit configuration_digest
          ].filter_map do |key|
            value = entry[key]
            "#{key}=#{value}" if value
          end
          "#{entry.fetch('name')} #{dimensions.join(' ')}"
        end

        def configuration_details(configuration, manifest)
          runtime_metadata = manifest.data.fetch("x-hive", {})
          {
            mappings: configuration.mapping_rows,
            optional_inputs: configuration.input_rows(
              runtime_metadata: runtime_metadata, environment: @environment
            )
          }
        end

        def project_config
          @project_config ||= Hive::Config.load(@project_root).merge("project_root" => @project_root)
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
