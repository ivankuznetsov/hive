require "stringio"
require "hive/attempts/store"
require "hive/commands/module/install"
require "hive/commands/module/state_change"
require "hive/commands/module/update"
require "hive/config"
require "hive/module_package/catalog_client"
require "hive/module_package/managed_store"
require "hive/modules/inspector"

module Hive
  module Web
    # Rails-facing boundary over the same preview/transaction engine as the
    # CLI. The browser's signed token is an additional transport guard; the
    # module receipt remains the CAS identity that authorizes the mutation.
    class ModuleLifecycle
      OPERATIONS = %w[install update enable disable uninstall].freeze

      def initialize(catalog_client_factory: -> { Hive::ModulePackage::CatalogClient.new },
                     committer: nil, attempt_store: nil, clock: -> { Time.now.utc })
        @catalog_client_factory = catalog_client_factory
        @committer = committer
        @attempt_store = attempt_store
        @clock = clock
      end

      def list(project, include_history: false)
        inspector(project).all(include_tombstones: include_history).map(&:to_h)
      end

      def preview(project, operation:, source: nil, name: nil, choices: {})
        operation = operation!(operation)
        command(
          project, operation:, source:, name:, choices:, dry_run: true, receipt: nil
        ).call!
      end

      def apply(project, operation:, source: nil, name: nil, choices: {}, receipt:)
        operation = operation!(operation)
        command(
          project, operation:, source:, name:, choices:, dry_run: false, receipt: receipt
        ).call!
      end

      private

      def command(project, operation:, source:, name:, choices:, dry_run:, receipt:)
        common = {
          project_root: project_root(project), json: true, stdout: StringIO.new,
          yes: !dry_run, dry_run: dry_run, receipt: receipt,
          store: store(project), committer: @committer
        }
        case operation
        when "install", "update"
          klass = operation == "install" ? Hive::Commands::Module::Install : Hive::Commands::Module::Update
          subject = operation == "install" ? source.to_s : name.to_s
          klass.new(
            subject, **common, settings: Array(choices[:settings] || choices["settings"]),
            hooks: Array(choices[:hooks] || choices["hooks"]),
            grants: Array(choices[:grants] || choices["grants"]),
            catalog_client: @catalog_client_factory.call
          )
        else
          Hive::Commands::Module::StateChange.new(operation, name.to_s, **common)
        end
      end

      def inspector(project)
        Hive::Modules::Inspector.new(
          store: store(project), attempt_store: @attempt_store,
          clock: @clock
        )
      end

      def store(project)
        Hive::ModulePackage::ManagedStore.new(project.fetch("hive_state_path"))
      end

      def project_root(project) = File.expand_path(project.fetch("path"))

      def operation!(operation)
        value = operation.to_s
        return value if OPERATIONS.include?(value)
        raise Hive::ConfigError, "unsupported module Web operation #{value.inspect}"
      end
    end
  end
end
