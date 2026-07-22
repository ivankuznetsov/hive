require "digest"

require "hive/agent_skills/adapters/base"

module Hive
  module AgentSkills
    module Adapters
      class Codex < Base
        AGENT = "codex"

        def plan(inspections)
          @successful_config_snapshots = {}
          super
        end

        protected

        def ownership_conflicts(native_spec, _rows)
          content = config_snapshot(native_spec).fetch("content")
          marketplace_source = section_value(content, marketplace_section_names(native_spec), "source")
          conflicts = []
          if marketplace_source && !same_source?(marketplace_source, native_spec.source)
            conflicts << "Codex marketplace #{native_spec.marketplace} is owned by #{marketplace_source.inspect}; Hive will not replace it"
          end

          plugin = native_spec.package.split("@", 2).first
          foreign = section_names(content).find do |section|
            section.start_with?("plugins.\"") &&
              section.match?(/\Aplugins\.\"#{Regexp.escape(plugin)}@/) &&
              section != "plugins.\"#{native_spec.package}\""
          end
          conflicts << "Codex plugin #{plugin} is already owned by #{foreign}; Hive will not replace it" if foreign
          conflicts
        end

        def operations_for_package(package, native_spec, rows)
          state = package_state(rows)
          bin = state.fetch("bin")
          path = config_path(native_spec)
          snapshot = config_snapshot(native_spec)
          common_metadata = {
            "config_path" => path,
            "snapshot" => snapshot,
            "native_package" => native_spec.package,
            "marketplace" => native_spec.marketplace
          }
          common_preconditions = {
            "config" => public_snapshot(snapshot),
            "unrelated_digest" => unrelated_digest(snapshot.fetch("content"), native_spec)
          }
          operations = []

          unless state["marketplace"]
            operations << operation(
              package: package,
              rows: rows,
              kind: "marketplace_add",
              argv: [ bin, "plugin", "marketplace", "add", native_spec.source, "--json" ],
              files: [ path ],
              metadata: common_metadata.merge("native_spec" => native_spec),
              preconditions: common_preconditions
            )
          end

          stale = rows.any? { |row| row.health == "stale" }
          if stale && state["marketplace"]
            operations << operation(
              package: package,
              rows: rows,
              kind: "marketplace_upgrade",
              argv: [ bin, "plugin", "marketplace", "upgrade", native_spec.marketplace, "--json" ],
              files: [ path ],
              depends_on: [ operations.last&.id ],
              metadata: common_metadata.merge("native_spec" => native_spec),
              preconditions: common_preconditions
            )
          end

          if state["package"].nil? || stale || rows.any? { |row| row.resolution["path"].nil? }
            operations << operation(
              package: package,
              rows: rows,
              kind: "plugin_install",
              argv: [ bin, "plugin", "add", native_spec.package, "--json" ],
              files: [ path, File.join(config_root(native_spec), "plugins", "cache") ],
              depends_on: [ operations.last&.id ],
              metadata: common_metadata.merge("native_spec" => native_spec),
              preconditions: common_preconditions
            )
          end
          operations
        end

        def validate_preconditions(operation)
          return super if operation.kind == "alias_write"
          path = operation.metadata.fetch("config_path")
          expected = operation.metadata.fetch("snapshot")
          current = file_snapshot(path)
          exact = current["exists"] == expected["exists"] && current["digest"] == expected["digest"]
          return nil if exact

          dependency_match = operation.depends_on.any? do |dependency|
            snapshot = @successful_config_snapshots&.fetch(dependency, nil)
            snapshot && current["exists"] == snapshot["exists"] && current["digest"] == snapshot["digest"]
          end
          return nil if dependency_match

          native_spec = operation.metadata.fetch("native_spec")
          if !operation.depends_on.empty? &&
             unrelated_digest(current.fetch("content"), native_spec) == unrelated_digest(expected.fetch("content"), native_spec)
            return nil
          end
          "#{path} changed since preview"
        end

        def before_command(operation)
          file_snapshot(operation.metadata.fetch("config_path"))
        end

        def after_command(operation, before)
          path = operation.metadata.fetch("config_path")
          return nil unless File.file?(path)
          native_spec = operation.metadata.fetch("native_spec")
          after = file_snapshot(path)
          if unrelated_digest(after.fetch("content"), native_spec) != unrelated_digest(before.fetch("content"), native_spec)
            return "Codex changed comments or unrelated config while applying #{operation.kind}"
          end
          File.chmod(before["mode"], path) if before["mode"] && after["mode"] != before["mode"]
          @successful_config_snapshots ||= {}
          @successful_config_snapshots[operation.id] = file_snapshot(path)
          nil
        end

        def rollback_failed_command(operation, before)
          return unless before
          path = operation.metadata.fetch("config_path")
          current = file_snapshot(path)
          native_spec = operation.metadata.fetch("native_spec")
          return unless unrelated_digest(current.fetch("content"), native_spec) == unrelated_digest(before.fetch("content"), native_spec)

          if before["exists"]
            Hive::AtomicFile.write(path, before.fetch("content"), mode: before.fetch("mode"))
          else
            FileUtils.rm_f(path)
          end
        end

        private

        def config_path(native_spec)
          File.join(config_root(native_spec), "config.toml")
        end

        def config_snapshot(native_spec)
          file_snapshot(config_path(native_spec))
        end

        def section_names(content)
          content.to_s.lines.filter_map { |line| line[/\A\s*\[([^\]]+)\]\s*\z/, 1] }
        end

        def marketplace_section_names(native_spec)
          [ "marketplaces.#{native_spec.marketplace}", "marketplaces.\"#{native_spec.marketplace}\"" ]
        end

        def section_value(content, names, key)
          current = nil
          content.to_s.each_line do |line|
            header = line[/\A\s*\[([^\]]+)\]\s*\z/, 1]
            current = header if header
            next unless names.include?(current)
            value = line[/\A\s*#{Regexp.escape(key)}\s*=\s*"([^"]*)"/, 1]
            return value if value
          end
          nil
        end

        def unrelated_digest(content, native_spec)
          ::Digest::SHA256.hexdigest(strip_owned_sections(content, native_spec))
        end

        def strip_owned_sections(content, native_spec)
          owned = marketplace_section_names(native_spec) + [ "plugins.\"#{native_spec.package}\"" ]
          output = []
          skip = false
          content.to_s.each_line do |line|
            if (header = line[/\A\s*\[([^\]]+)\]\s*\z/, 1])
              skip = owned.include?(header)
            end
            output << line unless skip
          end
          output.join
        end

        def same_source?(left, right)
          normalize_source(left) == normalize_source(right)
        end

        def normalize_source(value)
          value.to_s.sub(%r{\Ahttps://github\.com/}i, "").sub(/\.git\z/i, "").downcase
        end
      end
    end
  end
end
