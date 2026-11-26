require "hive/agent_skills"
require "hive/agent_support/agy"
require "hive/skill_check"

module Hive::AgentSupport::Agy
  # Antigravity CLI (`agy`) natively installs plugins from local paths or
  # GitHub repository URLs (including `.claude-plugin/plugin.json` bundles and
  # symlinks) into `~/.gemini/config/plugins/<name>`. Re-running
  # `agy plugin install <source>` replaces the installed tree in place while
  # preserving enablement in `~/.gemini/config/config.json`.
  class SetupAdapter < Hive::AgentSkills::Adapter
    AGENT = "agy"

    protected

    def ownership_conflicts(native_spec, _rows)
      root = config_root(native_spec)
      install_dir = Skills.installed_plugin_dir(native_spec.package, config_dir: root)
      return [] unless install_dir

      source = Skills.repository_source(install_dir)
      return [] if source && Hive::SkillCheck.same_source?(source, native_spec.source)

      [
        "agy plugin #{native_spec.package} at #{install_dir} is owned by " \
        "#{source.inspect}; Hive will not replace it"
      ]
    end

    def operations_for_package(package, native_spec, rows)
      state = package_state(rows)
      bin = state.fetch("bin")
      installed = state["package"]
      root = config_root(native_spec)
      files = [
        File.join(root, "plugins", native_spec.package),
        File.join(root, "config.json")
      ]

      if installed.nil?
        return [ operation(
          package: package,
          rows: rows,
          kind: "plugin_install",
          argv: [ bin, "plugin", "install", native_spec.source ],
          files: files
        ) ]
      end

      operations = []
      needs_update = rows.any? { |row| row.health == "stale" } ||
        (installed["enabled"] != false && rows.any? { |row| row.resolution["path"].nil? })
      if needs_update
        operations << operation(
          package: package,
          rows: rows,
          kind: "plugin_update",
          argv: [ bin, "plugin", "install", native_spec.source ],
          files: files
        )
      end
      if installed["enabled"] == false
        operations << operation(
          package: package,
          rows: rows,
          kind: "plugin_enable",
          argv: [ bin, "plugin", "enable", native_spec.package ],
          files: files,
          depends_on: [ operations.last&.id ]
        )
      end
      operations
    end
  end
end
