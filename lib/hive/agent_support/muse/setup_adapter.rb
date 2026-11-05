require "hive/agent_skills/adapters/base"
require "hive/agent_support/muse"

module Hive::AgentSupport::Muse
  # Muse cannot install plugin bundles that contain symlinks, and upstream
  # plugin repositories ship them, so a muse native package is provisioned
  # in two steps: Hive stages a dereferenced copy of the manifest git source
  # (see PluginStaging), then Muse installs or updates the plugin from
  # that staged tree with its own commands. Updates refresh the staging
  # first because `muse plugins update` re-reads the recorded source path.
  class SetupAdapter < Hive::AgentSkills::Adapters::Base
    AGENT = "muse"

    def execute(operation)
      return super unless operation.kind == "plugin_stage"

      version = PluginStaging.stage(
        source: operation.metadata.fetch("source"),
        root: operation.metadata.fetch("staging_root"),
        runner: @runner,
        env: runner_environment
      )
      Hive::AgentSkills::Adapters::Outcome.new(
        operation_id: operation.id, agent:, package_id: operation.package_id,
        status: "succeeded",
        message: "staged symlink-free muse plugin source (#{version})",
        exit_status: 0, changed_files: operation.files
      )
    rescue Hive::Error => e
      failed(operation, e.message)
    end

    protected

    def ownership_conflicts(native_spec, _rows)
      record = Skills.installed_plugin(
        native_spec.package, environment: @environment
      )
      return [] unless record.is_a?(Hash)

      source_path = record.dig("source", "path").to_s
      staged = PluginStaging.package_dir(staging_root(native_spec))
      return [] if !source_path.empty? &&
                   File.expand_path(source_path) == File.expand_path(staged)

      [
        "muse plugin #{native_spec.package} is installed from " \
        "#{source_path.inspect}; Hive will not replace it"
      ]
    end

    def operations_for_package(package, native_spec, rows)
      state = package_state(rows)
      bin = state.fetch("bin")
      installed = state["package"]
      root = staging_root(native_spec)
      data_dir = Hive::AgentSupport::Muse.data_directory(environment: @environment)
      registry = [ File.join(data_dir, "plugins", "installed.json") ]

      verb = if installed.nil?
        "plugin_install"
      elsif rows.any? { |row| row.health == "stale" || row.resolution["path"].nil? }
        "plugin_update"
      end
      operations = []
      if verb
        stage = operation(
          package: package, rows: rows, kind: "plugin_stage", argv: [],
          files: [ PluginStaging.package_dir(root) ],
          metadata: { "source" => native_spec.source, "staging_root" => root }
        )
        operations << stage
        argv = if verb == "plugin_install"
          [ bin, "plugins", "install", PluginStaging.package_dir(root), "--json" ]
        else
          [ bin, "plugins", "update", native_spec.package, "--json" ]
        end
        operations << operation(
          package: package, rows: rows, kind: verb, argv: argv,
          files: registry, depends_on: [ stage.id ]
        )
      end
      if installed && installed["enabled"] == false
        operations << operation(
          package: package, rows: rows, kind: "plugin_enable",
          argv: [ bin, "plugins", "enable", native_spec.package, "--json" ],
          files: registry, depends_on: [ operations.last&.id ]
        )
      end
      operations
    end

    private

    def staging_root(native_spec)
      PluginStaging.root(
        package_id: native_spec.package, environment: @environment
      )
    end
  end
end
