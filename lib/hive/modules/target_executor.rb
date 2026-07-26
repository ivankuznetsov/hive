require "digest"
require "fileutils"
require "json"
require "pathname"
require "rbconfig"
require "tempfile"
require "yaml"
require "hive/atomic_file"
require "hive/commands/new"
require "tmpdir"
require "hive/module_package/command_target"
require "hive/modules/capability_context"
require "hive/modules/entrypoints"
require "hive/modules/first_party"
require "hive/workflows/descriptor_parser"
require "hive/workflows/project"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/mutation_lock"

module Hive
  module Modules
    # Executes only the three declarative target kinds admitted by a reviewed
    # module manifest. Packaged workflows stop at an injectable admission seam
    # until task metadata can durably pin a module generation.
    class TargetExecutor
      class CommandRunner
        SAFE_ENV = %w[HOME LANG LC_ALL PATH TMPDIR].freeze
        MAX_OUTPUT_BYTES = 1_048_576
        RUNTIME_PATHS = %w[/usr /etc/ld.so.cache /etc/ssl /etc/ca-certificates].freeze

        def preflight!(grants:)
          unless RbConfig::CONFIG.fetch("host_os").include?("linux")
            raise Hive::ConfigError, "module command targets require Linux bubblewrap"
          end
          unless executable_path("bwrap")
            raise Hive::ConfigError, "module command targets require bubblewrap"
          end
          hosts = grants.fetch("network_hosts")
          unless hosts.empty? || hosts == [ "*" ]
            raise Hive::ConfigError,
                  "module command target host allowlists require an unavailable network sandbox"
          end
          true
        end

        def call(argv:, chdir:, environment: {}, grants:, secret_values: [])
          preflight!(grants: grants)
          env = SAFE_ENV.to_h { |name| [ name, ENV[name] ] }.compact.merge(environment)
          Tempfile.create("hive-module-stdout") do |stdout|
            Tempfile.create("hive-module-stderr") do |stderr|
              pid = Process.spawn(
                env, *sandbox_argv(argv: argv, chdir: chdir, grants: grants),
                chdir: chdir, in: :close, out: stdout, err: stderr, unsetenv_others: true
              )
              _waited, status = Process.wait2(pid)
              emit_redacted(stdout, $stdout, secret_values)
              emit_redacted(stderr, $stderr, secret_values)
              status.exited? ? status.exitstatus : 128 + status.termsig.to_i
            end
          end
        rescue SystemCallError
          raise Hive::ConfigError, "module command target could not start"
        end

        private

        def sandbox_argv(argv:, chdir:, grants:)
          project_root = File.expand_path(chdir)
          arguments = [ executable_path("bwrap"), "--unshare-all", "--die-with-parent", "--new-session" ]
          if grants.fetch("filesystem_write") == [ "*" ]
            arguments.concat([ "--bind", "/", "/" ])
          elsif grants.fetch("filesystem_read") == [ "*" ]
            arguments.concat([ "--ro-bind", "/", "/" ])
          else
            arguments.concat([ "--tmpfs", "/" ])
            bind_runtime_paths(arguments)
          end
          arguments.concat([ "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp" ])
          bind_project_paths(arguments, project_root, grants)
          arguments << "--share-net" unless grants.fetch("network_hosts").empty?
          arguments.concat([ "--chdir", project_root, "--", *argv ])
        end

        def bind_runtime_paths(arguments)
          RUNTIME_PATHS.each do |path|
            next unless File.exist?(path)
            ensure_sandbox_parents(arguments, path)
            arguments.concat([ "--ro-bind", path, path ])
          end
          %w[/bin /lib /lib64 /sbin].each do |path|
            next unless File.symlink?(path)
            arguments.concat([ "--symlink", File.readlink(path), path ])
          end
        end

        def bind_project_paths(arguments, project_root, grants)
          ensure_sandbox_parents(arguments, project_root)
          arguments.concat([ "--dir", project_root ])
          write_patterns = grants.fetch("filesystem_write")
          read_patterns = grants.fetch("filesystem_read")
          if grants.fetch("repository_write") || repository_granted?(write_patterns)
            arguments.concat([ "--bind", project_root, project_root ])
            return
          end
          if repository_granted?(read_patterns)
            arguments.concat([ "--ro-bind", project_root, project_root ])
          end
          bind_patterns(arguments, project_root, read_patterns, "--ro-bind")
          bind_patterns(arguments, project_root, write_patterns, "--bind")
        end

        def bind_patterns(arguments, project_root, patterns, option)
          patterns.grep_v(/\Arepository\z|\A\*\z/).each do |pattern|
            root = pattern.delete_suffix("/**")
            paths = Dir.glob(File.join(project_root, pattern), File::FNM_DOTMATCH)
            paths << File.join(project_root, root) if File.exist?(File.join(project_root, root))
            paths.uniq.each do |path|
              absolute = File.expand_path(path)
              next unless absolute.start_with?("#{project_root}#{File::SEPARATOR}")
              ensure_sandbox_parents(arguments, absolute)
              arguments.concat([ option, absolute, absolute ])
            end
          end
        end

        def repository_granted?(patterns)
          patterns.include?("repository") || patterns == [ "*" ]
        end

        def ensure_sandbox_parents(arguments, path)
          parents = Pathname.new(File.dirname(path)).ascend.to_a.reverse
          parents.each do |parent|
            value = parent.to_s
            next if value == "/" || arguments.each_cons(2).any? { |pair| pair == [ "--dir", value ] }
            arguments.concat([ "--dir", value ])
          end
        end

        def emit_redacted(file, output, secrets)
          file.flush
          file.rewind
          bytes = file.read(MAX_OUTPUT_BYTES + 1).to_s
          truncated = bytes.bytesize > MAX_OUTPUT_BYTES
          bytes = bytes.byteslice(0, MAX_OUTPUT_BYTES)
          Array(secrets).reject { |value| value.to_s.empty? }.each do |value|
            bytes = bytes.gsub(value.to_s, "[REDACTED]")
          end
          output.write(bytes)
          output.write("\n[hive: module command output truncated]\n") if truncated
        end

        def executable_path(name)
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |dir|
            path = File.join(dir, name)
            path if File.file?(path) && File.executable?(path)
          end.first
        end
      end

      class WorkflowRunner
        def call(project:, module_name:, hook_id:, event:, workflow:, descriptor_path:,
                 package_root:, target_snapshot:, configuration:)
          workflow_id = workflow_identity(
            module_name, workflow.id, configuration.digest, target_snapshot
          )
          install_workflow_snapshot(
            project, workflow_id, descriptor_path, package_root, target_snapshot
          )
          Hive::Workflows::Project.reset!
          slug = workflow_slug(module_name, hook_id, event.fetch("event_id"))
          return 0 if admitted_task?(project, workflow, slug, workflow_id)

          Hive::Commands::New.new(
            project.fetch("name"),
            "Module #{module_name} hook #{hook_id}",
            slug_override: slug,
            body_override: JSON.pretty_generate(
              "module" => module_name, "hook" => hook_id, "event" => event
            ),
            workflow: workflow_id
          ).call!
          0
        end

        private

        def install_workflow_snapshot(project, workflow_id, descriptor_path, package_root, snapshot)
          workflow_dir = File.join(project.fetch("hive_state_path"), "workflows")
          digest = ::Digest::SHA256.hexdigest(
            Hive::WorkflowPackage::CanonicalJSON.generate(snapshot)
          )
          asset_root = File.join(workflow_dir, ".module-workflows", digest)
          descriptor_relative = Pathname.new(descriptor_path)
                                        .relative_path_from(Pathname.new(package_root)).to_s
          Hive::WorkflowPackage::MutationLock.with_lock(workflow_dir) do
            snapshot.fetch("files").each do |file|
              next if file.fetch("path") == descriptor_relative

              write_immutable(
                File.join(asset_root, file.fetch("path")), file.fetch("content")
              )
            end
            data = YAML.safe_load(File.binread(descriptor_path))
            data["id"] = workflow_id
            rewrite_instruction_paths!(
              data, descriptor_dir: File.dirname(descriptor_relative),
              asset_prefix: Pathname.new(asset_root).relative_path_from(Pathname.new(workflow_dir)).to_s
            )
            write_immutable(
              File.join(workflow_dir, "#{workflow_id}.yml"),
              Hive::WorkflowPackage::CanonicalYAML.dump(data)
            )
          end
        end

        def rewrite_instruction_paths!(value, descriptor_dir:, asset_prefix:)
          case value
          when Hash
            value.each do |key, nested|
              if key.to_s == "instruction" && nested.is_a?(String)
                value[key] = File.join(asset_prefix, descriptor_dir, nested)
              else
                rewrite_instruction_paths!(
                  nested, descriptor_dir: descriptor_dir, asset_prefix: asset_prefix
                )
              end
            end
          when Array
            value.each do |nested|
              rewrite_instruction_paths!(
                nested, descriptor_dir: descriptor_dir, asset_prefix: asset_prefix
              )
            end
          end
        end

        def write_immutable(path, bytes)
          if File.file?(path)
            raise Hive::ConfigError, "module workflow snapshot identity collided" unless File.binread(path) == bytes
            return
          end
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          Hive::AtomicFile.write(path, bytes, mode: 0o400)
        end

        def admitted_task?(project, workflow, slug, workflow_id)
          path = File.join(
            project.fetch("hive_state_path"), "stages", workflow.stages.first.dir, slug
          )
          return false unless File.directory?(path)

          meta = Hive::TaskMeta.read_for_admission(path)
          unless meta.ok? && meta.data[:workflow] == workflow_id
            raise Hive::ConfigError, "module workflow task identity collided"
          end
          true
        end

        def workflow_identity(module_name, workflow_id, configuration_digest, snapshot)
          digest = ::Digest::SHA256.hexdigest(
            [ configuration_digest, Hive::WorkflowPackage::CanonicalJSON.generate(snapshot) ].join("\0")
          )
          "module-#{module_name}-#{workflow_id}-#{digest[0, 12]}"
        end

        def workflow_slug(module_name, hook_id, event_id)
          prefix = "module-#{module_name}-#{hook_id}".gsub(/[^a-z0-9-]/, "-")[0, 45]
          "#{prefix}-#{::Digest::SHA256.hexdigest(event_id.to_s)[0, 12]}"[0, 63].sub(/-\z/, "0")
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
        @workflow_runner = workflow_runner || WorkflowRunner.new
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
          when "command"
            command_argv!(target, configuration)
            @command_runner.preflight!(grants: configuration.grants) if @command_runner.respond_to?(:preflight!)
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
        environment = granted_environment(configuration)
        @command_runner.call(
          argv: argv, chdir: File.expand_path(project.fetch("path")),
          environment: environment,
          grants: configuration.grants,
          secret_values: environment.values
        )
      end

      def granted_environment(configuration)
        bindings = configuration.grants.fetch("secrets")
        configuration.contract.fetch("settings").filter_map do |setting|
          next unless setting.fetch("type") == "secret"
          binding = configuration.settings.fetch(setting.fetch("name"))
          next unless binding && bindings.include?(binding)

          [ binding, ENV.fetch(binding) ]
        end.to_h
      rescue KeyError
        raise CapabilityDenied, "module command target secret binding is unavailable"
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
    end
  end
end
