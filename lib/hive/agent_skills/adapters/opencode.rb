require "json"

require "hive/agent_skills/adapters/base"

module Hive
  module AgentSkills
    module Adapters
      class OpenCode < Base
        AGENT = "opencode"

        def execute(operation)
          return super unless operation.kind == "plugin_configure"

          error = validate_preconditions(operation)
          return failed(operation, error) if error

          path = operation.metadata.fetch("config_path")
          snapshot = operation.metadata.fetch("snapshot")
          document = snapshot.fetch("content").empty? ? {} :
            JSON.parse(snapshot.fetch("content"))
          unless document.is_a?(Hash)
            return failed(operation, "#{path} must contain a JSON object")
          end
          plugins = document.fetch("plugin", [])
          unless plugins.is_a?(Array) && plugins.all? { |entry| entry.is_a?(String) }
            return failed(operation, "#{path} plugin must be an array of strings")
          end
          document["plugin"] = (plugins + [ operation.metadata.fetch("plugin") ]).uniq
          Hive::AtomicFile.write(
            path, JSON.pretty_generate(document) + "\n",
            mode: snapshot["mode"] || 0o600
          )
          Outcome.new(
            operation_id: operation.id, agent: agent,
            package_id: operation.package_id, status: "succeeded",
            message: "configured pinned OpenCode plugin", exit_status: 0,
            changed_files: [ path ].freeze
          )
        rescue JSON::ParserError => e
          failed(operation, "#{path} is invalid JSON: #{e.message}")
        end

        protected

        def ownership_conflicts(native_spec, _rows)
          snapshot = config_snapshot(native_spec)
          return [] if snapshot.fetch("content").empty?

          document = JSON.parse(snapshot.fetch("content"))
          plugins = document.fetch("plugin", [])
          return [ "OpenCode plugin configuration must be an array" ] unless
            plugins.is_a?(Array)
          foreign = plugins.find do |entry|
            entry.to_s.start_with?("compound-engineering@") &&
              entry != native_spec.package
          end
          foreign ? [
            "OpenCode Compound Engineering plugin is already pinned by #{foreign.inspect}; " \
            "Hive will not replace it"
          ] : []
        rescue JSON::ParserError => e
          [ "OpenCode config is invalid JSON: #{e.message}" ]
        end

        def operations_for_package(package, native_spec, rows)
          snapshot = config_snapshot(native_spec)
          plugins = begin
            content = snapshot.fetch("content")
            content.empty? ? [] : Array(JSON.parse(content)["plugin"])
          end
          return [] if plugins.include?(native_spec.package) &&
                       rows.none? { |row| row.health == "stale" }

          [ operation(
            package: package, rows: rows, kind: "plugin_configure", argv: [],
            files: [ config_path(native_spec) ],
            preconditions: { "config" => public_snapshot(snapshot) },
            metadata: {
              "config_path" => config_path(native_spec),
              "snapshot" => snapshot,
              "plugin" => native_spec.package
            }
          ) ]
        end

        def validate_preconditions(operation)
          return super unless operation.kind == "plugin_configure"

          expected = operation.metadata.fetch("snapshot")
          current = file_snapshot(operation.metadata.fetch("config_path"))
          return nil if current["exists"] == expected["exists"] &&
                        current["digest"] == expected["digest"]

          "#{operation.metadata.fetch('config_path')} changed since preview"
        end

        private

        def config_path(native_spec)
          File.join(config_root(native_spec), "opencode.json")
        end

        def config_snapshot(native_spec)
          file_snapshot(config_path(native_spec))
        end
      end
    end
  end
end
