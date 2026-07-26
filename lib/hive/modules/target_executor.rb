require "digest"
require "fileutils"
require "pathname"
require "tmpdir"
require "hive/module_package/command_target"
require "hive/modules/capability_context"
require "hive/modules/entrypoints"
require "hive/modules/first_party"
require "hive/workflows/descriptor_parser"

module Hive
  module Modules
    # Executes only the three declarative target kinds admitted by a reviewed
    # module manifest. Packaged workflows stop at an injectable admission seam
    # until task metadata can durably pin a module generation.
    class TargetExecutor
      class CommandRunner
        def call(argv:, chdir:)
          pid = Process.spawn(*argv, chdir: chdir, in: :close)
          _waited, status = Process.wait2(pid)
          status.exited? ? status.exitstatus : 128 + status.termsig.to_i
        rescue SystemCallError
          raise Hive::ConfigError, "module command target could not start"
        end
      end

      def self.capture_snapshot(target:, configuration:, package_root: nil)
        new(first_party_loader: -> { true }).capture_snapshot(
          target: target, configuration: configuration, package_root: package_root
        )
      end

      def initialize(entrypoints: Hive::Modules::Entrypoints,
                     first_party_loader: Hive::Modules::FirstParty.method(:load!),
                     command_runner: CommandRunner.new, workflow_runner: nil)
        @entrypoints = entrypoints
        @first_party_loader = first_party_loader
        @command_runner = command_runner
        @workflow_runner = workflow_runner || method(:workflow_admission_unavailable!)
      end

      # ManagedStore's health-check signature is positional. The returned
      # callable validates bindings and prerequisites without invoking a hook.
      def health_check
        ->(package_root, configuration) { validate_generation!(package_root, configuration) }
      end

      def validate_generation!(package_root, configuration)
        @first_party_loader.call
        configuration.contract.fetch("hooks").each do |hook|
          target = hook.fetch("target")
          case target.fetch("kind")
          when "entrypoint" then @entrypoints.fetch(target.fetch("id"))
          when "command" then command_argv!(target, configuration)
          when "workflow"
            capture_snapshot(
              target: target, configuration: configuration, package_root: package_root
            )
          else
            raise Hive::ConfigError, "module hook target kind is unsupported"
          end
        end
        true
      rescue KeyError, TypeError
        raise Hive::ConfigError, "module target contract is malformed"
      end

      def capture_snapshot(target:, configuration:, package_root: nil)
        kind = target.fetch("kind")
        id = target.fetch("id")
        case kind
        when "entrypoint"
          { "kind" => kind, "id" => id }.freeze
        when "command"
          { "kind" => kind, "id" => id, "argv" => command_argv!(target, configuration) }.freeze
        when "workflow"
          capture_workflow(target, configuration, package_root)
        else
          raise Hive::ConfigError, "module hook target kind is unsupported"
        end
      rescue KeyError, TypeError
        raise Hive::ConfigError, "module target contract is malformed"
      end

      def call(target:, target_snapshot:, project:, module_name:, hook_id:, event:,
               configuration:)
        unless target_snapshot.is_a?(Hash) &&
               target_snapshot["kind"] == target.fetch("kind") &&
               target_snapshot["id"] == target.fetch("id")
          raise Hive::ConfigError, "module target snapshot identity does not match"
        end

        result = case target.fetch("kind")
        when "entrypoint"
          @first_party_loader.call
          @entrypoints.fetch(target.fetch("id")).call(
            project: project, module_name: module_name, hook_id: hook_id,
            event: event, configuration: configuration
          )
        when "command"
          execute_command(target, target_snapshot, project, configuration)
        when "workflow"
          execute_workflow(
            target, target_snapshot, project: project, module_name: module_name,
            hook_id: hook_id, event: event, configuration: configuration
          )
        else
          raise Hive::ConfigError, "module hook target kind is unsupported"
        end
        Integer(result || 0)
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "module target result is malformed"
      end

      private

      def command_argv!(target, configuration)
        argv = Hive::ModulePackage::CommandTarget.argv(target.fetch("id"))
        grants = configuration.grants.fetch("external_commands")
        unless grants.include?(argv.first)
          raise CapabilityDenied, "module command target executable is not granted"
        end
        argv
      end

      def execute_command(target, snapshot, project, configuration)
        argv = command_argv!(target, configuration)
        unless snapshot.keys.sort == %w[argv id kind] && snapshot.fetch("argv") == argv
          raise Hive::ConfigError, "module command target snapshot is malformed"
        end
        @command_runner.call(argv: argv, chdir: File.expand_path(project.fetch("path")))
      end

      def capture_workflow(target, configuration, package_root)
        root = File.expand_path(package_root.to_s)
        raise Hive::ConfigError, "module workflow generation is unavailable" unless File.directory?(root)

        declaration = declared_workflow!(target.fetch("id"), configuration)
        descriptor_path = File.join(root, declaration.fetch("descriptor"))
        workflow = Hive::Workflows::DescriptorParser.parse_package_file(
          descriptor_path, package_name: target.fetch("id")
        )
        paths = [ descriptor_path, *instruction_paths(workflow) ].uniq
        files = paths.map { |path| snapshot_file(root, path, configuration) }
                     .sort_by { |row| row.fetch("path") }
        {
          "kind" => "workflow", "id" => target.fetch("id"),
          "descriptor" => declaration.fetch("descriptor"), "files" => files
        }.freeze
      rescue Hive::ConfigError
        raise
      rescue SystemCallError, IOError
        raise Hive::ConfigError, "module workflow generation is unavailable"
      end

      def execute_workflow(target, snapshot, **context)
        declaration = declared_workflow!(target.fetch("id"), context.fetch(:configuration))
        validate_workflow_snapshot_shape!(snapshot, declaration)
        Dir.mktmpdir("hive-module-workflow-") do |root|
          materialize_snapshot!(root, snapshot.fetch("files"), context.fetch(:configuration))
          descriptor_path = File.join(root, declaration.fetch("descriptor"))
          workflow = Hive::Workflows::DescriptorParser.parse_package_file(
            descriptor_path, package_name: target.fetch("id")
          )
          @workflow_runner.call(
            **context, workflow: workflow, descriptor_path: descriptor_path,
            package_root: root, target_snapshot: snapshot
          )
        end
      end

      def declared_workflow!(id, configuration)
        declaration = configuration.contract.fetch("workflows").find do |workflow|
          workflow.fetch("id") == id
        end
        raise Hive::ConfigError, "module workflow target is not declared" unless declaration

        declaration
      end

      def instruction_paths(workflow)
        workflow.flat_map do |stage|
          paths = [ stage.instruction ]
          paths.concat(Array(stage.reviewers).map(&:instruction))
          paths << stage.council&.revise&.instruction
          paths.compact
        end
      end

      def snapshot_file(root, path, configuration)
        absolute = File.expand_path(path)
        unless absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
          raise Hive::ConfigError, "module workflow snapshot path escapes its generation"
        end
        relative = Pathname.new(absolute).relative_path_from(Pathname.new(root)).to_s
        expected = file_inventory(configuration).fetch(relative) do
          raise Hive::ConfigError, "module workflow snapshot file is undeclared"
        end
        bytes = File.binread(absolute)
        unless ::Digest::SHA256.hexdigest(bytes) == expected
          raise Hive::ConfigError, "module workflow snapshot file digest does not match"
        end
        { "path" => relative, "sha256" => expected, "content" => bytes }
      end

      def validate_workflow_snapshot_shape!(snapshot, declaration)
        unless snapshot.keys.sort == %w[descriptor files id kind] &&
               snapshot.fetch("kind") == "workflow" &&
               snapshot.fetch("descriptor") == declaration.fetch("descriptor") &&
               snapshot.fetch("files").is_a?(Array) && snapshot.fetch("files").any?
          raise Hive::ConfigError, "module workflow target snapshot is malformed"
        end
      end

      def materialize_snapshot!(root, files, configuration)
        seen = []
        files.each do |file|
          unless file.is_a?(Hash) && file.keys.sort == %w[content path sha256]
            raise Hive::ConfigError, "module workflow target snapshot is malformed"
          end
          relative = safe_relative_path!(file.fetch("path"))
          raise Hive::ConfigError, "module workflow target snapshot has duplicate files" if seen.include?(relative)
          seen << relative
          expected = file_inventory(configuration).fetch(relative) do
            raise Hive::ConfigError, "module workflow snapshot file is undeclared"
          end
          content = file.fetch("content")
          unless content.is_a?(String) && file.fetch("sha256") == expected &&
                 ::Digest::SHA256.hexdigest(content) == expected
            raise Hive::ConfigError, "module workflow snapshot file digest does not match"
          end
          destination = File.join(root, relative)
          FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
          File.binwrite(destination, content)
        end
      end

      def safe_relative_path!(value)
        path = Pathname.new(value.to_s)
        invalid = value.to_s.empty? || value.to_s.include?("\\") || value.to_s.include?("\0") ||
          path.absolute? || value.to_s.split("/").any? { |part| part.empty? || %w[. ..].include?(part) }
        raise Hive::ConfigError, "module workflow target snapshot path is malformed" if invalid

        value
      end

      def file_inventory(configuration)
        configuration.contract.fetch("files").to_h do |entry|
          [ entry.fetch("path"), entry.fetch("sha256") ]
        end
      end

      def workflow_admission_unavailable!(**)
        raise Hive::ConfigError,
              "module-pinned workflow task admission is unavailable"
      end
    end
  end
end
