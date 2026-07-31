require "digest"
require "fileutils"
require "pathname"
require "rbconfig"
require "tmpdir"
require "hive/errors"
require "hive/modules/migration/qualification_target_inventory"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Builds the only filesystem/process capability set granted to a
      # qualification candidate. Both lanes remain network-isolated and
      # receive no provider or GitHub secrets; live access belongs to a
      # future host-owned broker, never to candidate code.
      class CandidateExecutionSandbox
        class TargetChanged < Hive::ConfigError; end
        class CleanupFailed < Hive::ConfigError; end

        BWRAP = "/usr/bin/bwrap".freeze
        VIRTUAL_ROOT = "/qualification".freeze
        SOURCE_MOUNTS = %w[
          bin/hive config lib modules/architecture-patrol modules/patrol
          schemas templates
        ].freeze
        SYSTEM_RUNTIME_ROOTS = %w[
          /usr /bin /lib /lib64
        ].freeze
        SYSTEM_RUNTIME_FILES = %w[
          /etc/group /etc/ld.so.cache /etc/nsswitch.conf /etc/passwd
        ].freeze

        Launch = Data.define(
          :command, :environment, :host_cwd, :hive_home,
          :attempts_root, :custody_root, :network_isolated,
          :profile_sha256, :source_inventory,
          :installed_inventory
        )

        def initialize(
          bwrap: BWRAP,
          inventory: QualificationTargetInventory.new
        )
          @bwrap = bwrap.to_s
          @inventory = inventory
        end

        def call(
          executable:, argv:, workspace:, source_root:,
          installed_root:, case_root:, request_ref:, scenario_ref:,
          network:, credentials:, hive_home:
        )
          raise ArgumentError, "block required" unless block_given?

          roots = validate_roots(
            workspace: workspace,
            source_root: source_root,
            installed_root: installed_root,
            case_root: case_root,
            hive_home: hive_home
          )
          refs = validate_inputs(
            roots.fetch(:workspace),
            request_ref: request_ref,
            scenario_ref: scenario_ref
          )
          target = validate_executable(
            executable,
            source_root: roots.fetch(:source),
            installed_root: roots.fetch(:installed)
          )
          arguments = validate_argv(argv, roots.fetch(:workspace))
          network = validate_network(network)
          credentials = validate_credentials(
            credentials,
            network: network
          )
          validate_bwrap!
          before_source = @inventory.call(roots.fetch(:source))
          before_installed = @inventory.call(
            roots.fetch(:installed)
          )
          runtime = prepare_runtime(roots.fetch(:case))
          scaffold = build_scaffold(
            case_id: roots.fetch(:case_id),
            refs: refs,
            source_root: roots.fetch(:source),
            source_mounts:
              source_mounts(target, roots.fetch(:source))
          )
          launch = build_launch(
            roots: roots,
            refs: refs,
            target: target,
            argv: arguments,
            network: network,
            credentials: credentials,
            runtime: runtime,
            scaffold: scaffold,
            source_inventory: before_source,
            installed_inventory: before_installed
          )
          yield launch
        ensure
          if roots && before_source && before_installed
            after_source = @inventory.call(roots.fetch(:source))
            after_installed = @inventory.call(
              roots.fetch(:installed)
            )
            unless
              before_source.digest == after_source.digest &&
                before_installed.digest ==
                  after_installed.digest
              raise TargetChanged,
                    "patrol qualification candidate target changed"
            end
          end
          remove_scaffold(scaffold)
        end

        private

        def build_launch(
          roots:, refs:, target:, argv:, network:, credentials:,
          runtime:, scaffold:, source_inventory:,
          installed_inventory:
        )
          virtual_case =
            "#{VIRTUAL_ROOT}/cases/#{roots.fetch(:case_id)}"
          virtual_source = "#{VIRTUAL_ROOT}/targets/source"
          virtual_installed =
            "#{VIRTUAL_ROOT}/targets/installed"
          virtual_executable =
            virtual_target_path(
              target,
              source_root: roots.fetch(:source),
              installed_root: roots.fetch(:installed)
            )
          virtual_runtime = "#{virtual_case}/runtime"
          environment = {
            "HOME" => "#{virtual_runtime}/home",
            "HIVE_HOME" =>
              "#{virtual_case}/sandbox/hive-home",
            "XDG_CONFIG_HOME" =>
              "#{virtual_runtime}/xdg/config",
            "XDG_CACHE_HOME" =>
              "#{virtual_runtime}/xdg/cache",
            "XDG_DATA_HOME" =>
              "#{virtual_runtime}/xdg/data",
            "XDG_STATE_HOME" =>
              "#{virtual_runtime}/xdg/state",
            "TMPDIR" => "#{virtual_runtime}/tmp",
            "LANG" => "C.UTF-8",
            "LC_ALL" => "C.UTF-8",
            "TZ" => "UTC",
            "PATH" => [
              "#{virtual_installed}/bin",
              "#{virtual_installed}/rubygems-bin",
              File.join(ruby_prefix, "bin"),
              "/usr/bin",
              "/bin"
            ].uniq.join(File::PATH_SEPARATOR),
            "GEM_HOME" => virtual_installed,
            "GEM_PATH" => virtual_installed,
            "BUNDLE_DISABLE_SHARED_GEMS" => "true",
            "BUNDLE_FROZEN" => "true",
            "GIT_CONFIG_NOSYSTEM" => "1",
            "GIT_CONFIG_GLOBAL" => "/dev/null",
            "GIT_TERMINAL_PROMPT" => "0",
            "HIVE_BIN" => virtual_executable,
            "HIVE_INVOKED_BIN" => virtual_executable,
            "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
            "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
            "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1",
            "HIVE_QUALIFICATION_CUSTODY_ROOT" =>
              "#{virtual_runtime}/custody"
          }.merge(credentials).freeze
          virtual_argv = argv.map do |item|
            item == roots.fetch(:workspace) ?
              VIRTUAL_ROOT : item
          end.freeze
          profile = profile_digest(
            source_inventory: source_inventory,
            installed_inventory: installed_inventory,
            source_mounts:
              source_mounts(target, roots.fetch(:source))
          )
          command = bwrap_command(
            scaffold: scaffold,
            roots: roots,
            refs: refs,
            target: target,
            virtual_executable: virtual_executable,
            virtual_argv: virtual_argv,
            network: network
          )
          Launch.new(
            command: command,
            environment: environment,
            host_cwd: File::SEPARATOR,
            hive_home: roots.fetch(:hive_home),
            attempts_root: File.join(
              roots.fetch(:hive_home),
              "attempts",
              "v2"
            ),
            custody_root: runtime.fetch(:custody),
            network_isolated: !network,
            profile_sha256: profile,
            source_inventory: source_inventory,
            installed_inventory: installed_inventory
          ).freeze
        end

        def bwrap_command(
          scaffold:, roots:, refs:, target:,
          virtual_executable:, virtual_argv:, network:
        )
          command = [
            @bwrap,
            "--unshare-all",
            "--unshare-user",
            "--die-with-parent",
            "--new-session",
            "--disable-userns",
            "--assert-userns-disabled",
            "--cap-drop", "ALL"
          ]
          runtime_mounts.each do |source|
            command.concat(
              [ "--ro-bind", source, source ]
            )
          end
          command.concat(
            [ "--dev", "/dev", "--proc", "/proc",
              "--tmpfs", "/tmp" ]
          )
          command.concat(
            [ "--ro-bind", scaffold, VIRTUAL_ROOT ]
          )
          source_mounts(target, roots.fetch(:source)).each do |ref|
            command.concat(
              [
                "--ro-bind",
                File.join(roots.fetch(:source), ref),
                "#{VIRTUAL_ROOT}/targets/source/#{ref}"
              ]
            )
          end
          command.concat(
            [
              "--ro-bind", roots.fetch(:installed),
              "#{VIRTUAL_ROOT}/targets/installed",
              "--ro-bind",
              File.join(roots.fetch(:workspace), refs.fetch(:request)),
              "#{VIRTUAL_ROOT}/#{refs.fetch(:request)}",
              "--ro-bind",
              File.join(roots.fetch(:workspace), refs.fetch(:scenario)),
              "#{VIRTUAL_ROOT}/#{refs.fetch(:scenario)}",
              "--bind", roots.fetch(:case),
              "#{VIRTUAL_ROOT}/cases/#{roots.fetch(:case_id)}",
              "--chdir", VIRTUAL_ROOT,
              "--",
              virtual_executable,
              *virtual_argv
            ]
          )
          command.freeze
        end

        def runtime_mounts
          roots = SYSTEM_RUNTIME_ROOTS.filter_map do |path|
            path if File.exist?(path)
          end
          roots << ruby_prefix unless roots.any? do |root|
            ruby_prefix == root ||
              ruby_prefix.start_with?("#{root}/")
          end
          files = SYSTEM_RUNTIME_FILES.select do |path|
            File.file?(path)
          end
          (roots + files).uniq.freeze
        end

        def source_mounts(target, source_root)
          relative =
            relative_path(target, source_root)
          (SOURCE_MOUNTS + [ relative ]).uniq.select do |ref|
            path = File.join(source_root, ref)
            File.exist?(path) && !File.symlink?(path)
          end.sort.freeze
        end

        def profile_digest(
          source_inventory:, installed_inventory:,
          source_mounts:
        )
          payload = {
            "schema" =>
              "hive-qualification-candidate-sandbox-profile",
            "schema_version" => 1,
            "network" => "isolated",
            "mounts" => {
              "source" => source_mounts,
              "installed" => "read_only",
              "request" => "current_read_only",
              "scenario" => "current_read_only",
              "case" => "current_read_write"
            },
            "namespaces" => %w[
              cgroup ipc pid user uts
            ],
            "source_inventory_sha256" =>
              source_inventory.digest,
            "installed_inventory_sha256" =>
              installed_inventory.digest,
            "ruby_sha256" =>
              Digest::SHA256.file(RbConfig.ruby).hexdigest
          }
          Digest::SHA256.hexdigest(
            Hive::WorkflowPackage::CanonicalJSON.generate(payload)
          ).freeze
        end

        def build_scaffold(
          case_id:, refs:, source_root:, source_mounts:
        )
          root = Dir.mktmpdir("hive-qualification-view-")
          File.chmod(0o700, root)
          directories = [
            "targets/source",
            "targets/installed",
            "cases/#{case_id}",
            File.dirname(refs.fetch(:request)),
            File.dirname(refs.fetch(:scenario))
          ]
          source_mounts.each do |ref|
            destination =
              File.join(root, "targets/source", ref)
            host = File.join(source_root, ref)
            directories <<
              (File.directory?(host) ?
                destination : File.dirname(destination))
          end
          directories.uniq.sort_by { |path| path.count("/") }.each do |path|
            next if path == "."

            absolute = path.start_with?(root) ?
              path : File.join(root, path)
            FileUtils.mkdir_p(absolute, mode: 0o700)
            chmod_tree(absolute, stop: root)
          end
          file_destinations = [
            refs.fetch(:request),
            refs.fetch(:scenario)
          ]
          source_mounts.each do |ref|
            host = File.join(source_root, ref)
            next if File.directory?(host)

            file_destinations << "targets/source/#{ref}"
          end
          file_destinations.uniq.each do |relative|
            path = File.join(root, relative)
            next if File.directory?(path)

            FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
            File.binwrite(path, "")
            File.chmod(0o600, path)
          end
          root.freeze
        rescue SystemCallError, ArgumentError
          remove_scaffold(root)
          raise Hive::ConfigError,
                "patrol qualification sandbox is unavailable"
        end

        def chmod_tree(path, stop:)
          current = path
          loop do
            File.chmod(0o700, current)
            break if current == stop
            break unless current.start_with?("#{stop}/")

            current = File.dirname(current)
          end
        end

        def prepare_runtime(case_root)
          runtime = File.join(case_root, "runtime")
          values = {
            root: runtime,
            home: File.join(runtime, "home"),
            xdg: File.join(runtime, "xdg"),
            tmp: File.join(runtime, "tmp"),
            custody: File.join(runtime, "custody")
          }
          [
            values.fetch(:root),
            values.fetch(:home),
            values.fetch(:xdg),
            File.join(values.fetch(:xdg), "config"),
            File.join(values.fetch(:xdg), "cache"),
            File.join(values.fetch(:xdg), "data"),
            File.join(values.fetch(:xdg), "state"),
            values.fetch(:tmp),
            values.fetch(:custody)
          ].each do |path|
            FileUtils.mkdir_p(path, mode: 0o700)
            File.chmod(0o700, path)
          end
          values.freeze
        end

        def validate_roots(
          workspace:, source_root:, installed_root:,
          case_root:, hive_home:
        )
          workspace = directory(workspace, "workspace")
          source = child_directory(
            source_root, workspace, "source target"
          )
          installed = child_directory(
            installed_root, workspace, "installed target"
          )
          case_path = child_directory(
            case_root, workspace, "case"
          )
          case_id = File.basename(case_path)
          unless
            case_path ==
              File.join(workspace, "cases", case_id) &&
              case_id.match?(
                /\A[a-z0-9][a-z0-9._-]{0,127}\z/
              )
            malformed!("case")
          end
          home = hive_home.to_s
          unless
            home ==
              File.join(case_path, "sandbox", "hive-home")
            malformed!("HIVE_HOME")
          end
          {
            workspace: workspace,
            source: source,
            installed: installed,
            case: case_path,
            case_id: case_id.freeze,
            hive_home: home.freeze
          }.freeze
        end

        def validate_inputs(workspace, request_ref:, scenario_ref:)
          request = safe_ref(
            request_ref,
            prefix: "requests/",
            suffix: ".json"
          )
          scenario = safe_ref(
            scenario_ref,
            prefix: "inputs/scenarios/",
            suffix: ".yml"
          )
          [ request, scenario ].each do |ref|
            path = File.join(workspace, ref)
            stat = File.lstat(path)
            unless
              stat.file? &&
                !stat.symlink? &&
                stat.nlink == 1 &&
                stat.uid == Process.euid &&
                (stat.mode & 0o777) == 0o600
              malformed!("input")
            end
          end
          { request: request, scenario: scenario }.freeze
        rescue SystemCallError
          malformed!("input")
        end

        def validate_executable(value, source_root:, installed_root:)
          path = value.to_s
          root = [ source_root, installed_root ].find do |candidate|
            path.start_with?("#{candidate}/")
          end
          malformed!("executable") unless root
          stat = File.lstat(path)
          unless
            stat.file? &&
              !stat.symlink? &&
              stat.nlink == 1 &&
              stat.uid == Process.euid &&
              (stat.mode & 0o111).positive? &&
              (stat.mode & 0o022).zero? &&
              File.realpath(path) == path
            malformed!("executable")
          end
          path.freeze
        rescue SystemCallError
          malformed!("executable")
        end

        def validate_argv(value, workspace)
          unless
            value.is_a?(Array) &&
              value.length <= 64 &&
              value.all? do |item|
                item.is_a?(String) &&
                  !item.empty? &&
                  item.bytesize <= 4_096 &&
                  !item.include?("\0") &&
                  (
                    !Pathname.new(item).absolute? ||
                      item == workspace ||
                      item.start_with?("#{VIRTUAL_ROOT}/")
                  )
              end
            malformed!("argv")
          end
          value.map { |item| item.dup.freeze }.freeze
        rescue ArgumentError
          malformed!("argv")
        end

        def validate_network(value)
          malformed!("network policy") unless value == false

          false
        end

        def validate_credentials(value, network:)
          unless
            value.is_a?(Hash) &&
              value.empty? &&
              network == false
            malformed!("credentials")
          end
          {}.freeze
        end

        def validate_bwrap!
          stat = File.lstat(@bwrap)
          unless
            @bwrap == File.expand_path(@bwrap) &&
              stat.file? &&
              !stat.symlink? &&
              stat.uid.zero? &&
              (stat.mode & 0o022).zero? &&
              (stat.mode & 0o111).positive?
            raise Hive::ConfigError,
                  "patrol qualification sandbox is unavailable"
          end
        rescue SystemCallError
          raise Hive::ConfigError,
                "patrol qualification sandbox is unavailable"
        end

        def directory(value, label)
          path = value.to_s
          unless
            !path.empty? &&
              !path.include?("\0") &&
              path == File.expand_path(path)
            malformed!(label)
          end
          stat = File.lstat(path)
          unless
            stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o077).zero? &&
              File.realpath(path) == path
            malformed!(label)
          end
          path.freeze
        rescue SystemCallError
          malformed!(label)
        end

        def child_directory(value, parent, label)
          path = directory(value, label)
          malformed!(label) unless path.start_with?("#{parent}/")
          path
        end

        def safe_ref(value, prefix:, suffix:)
          text = value.to_s
          path = Pathname.new(text)
          unless
            text.start_with?(prefix) &&
              text.end_with?(suffix) &&
              !path.absolute? &&
              path.cleanpath.to_s == text &&
              !text.include?("\\") &&
              !text.include?("\0") &&
              text.split("/").none? do |part|
                part.empty? || part == "." || part == ".."
              end
            malformed!("input")
          end
          text.freeze
        rescue ArgumentError
          malformed!("input")
        end

        def relative_path(path, root)
          path.delete_prefix("#{root}/")
        end

        def virtual_target_path(
          path, source_root:, installed_root:
        )
          if path.start_with?("#{source_root}/")
            "#{VIRTUAL_ROOT}/targets/source/" \
              "#{relative_path(path, source_root)}"
          else
            "#{VIRTUAL_ROOT}/targets/installed/" \
              "#{relative_path(path, installed_root)}"
          end.freeze
        end

        def ruby_prefix
          @ruby_prefix ||= begin
            path = File.expand_path(
              RbConfig::CONFIG.fetch("prefix")
            )
            stat = File.lstat(path)
            unless
              stat.directory? &&
                !stat.symlink? &&
                File.realpath(path) == path
              raise Hive::ConfigError,
                    "patrol qualification Ruby runtime is unavailable"
            end
            path.freeze
          end
        end

        def remove_scaffold(path)
          return unless path &&
                        path.start_with?(
                          File.join(Dir.tmpdir, "hive-qualification-view-")
                        ) &&
                        File.directory?(path) &&
                        !File.symlink?(path)

          FileUtils.remove_entry_secure(path)
        rescue SystemCallError, ArgumentError
          raise CleanupFailed,
                "patrol qualification sandbox cleanup failed"
        end

        def malformed!(label)
          raise Hive::ConfigError,
                "patrol qualification #{label} is unsafe"
        end
      end
    end
  end
end
