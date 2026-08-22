require "fileutils"
require "rbconfig"
require "tmpdir"
require "hive"
require "hive/invoked_binary"
require "hive/workflow_package/runtime_policy"

module Hive
  module Artifacts
    # Minimal filesystem and environment boundary shared by controller-side
    # evidence commands. The committed source is readable, conventional runtime
    # directories are writable, and the operator's home and credentials do not
    # exist inside the namespace.
    class ProjectCommandSandbox
      WRITABLE_SOURCE_DIRS = %w[log storage tmp].freeze
      SAFE_ENVIRONMENT_KEYS = %w[
        LANG LC_ALL LC_CTYPE TERM COLORTERM TZ SSL_CERT_FILE SSL_CERT_DIR
      ].freeze

      class SandboxError < Hive::Error; end

      def initialize(source_root:, environment: ENV, sandbox_binary: nil,
                     share_network: false, extra_environment: {},
                     runtime_overlay_root: nil)
        @source_root = File.realpath(source_root)
        @environment = environment.to_h
        @sandbox_binary = sandbox_binary || Hive::InvokedBinary.which("bwrap")
        @share_network = share_network == true
        @extra_environment = extra_environment.to_h.transform_keys(&:to_s)
        @runtime_overlay_root = runtime_overlay_root && File.realpath(runtime_overlay_root)
        validate_extra_environment!
        validate_overlay_root! if @runtime_overlay_root
      rescue Errno::ENOENT, Errno::EACCES, ArgumentError, TypeError => e
        raise SandboxError, "project evidence sandbox is unavailable: #{e.message}"
      end

      def command_argv(command)
        prepare_runtime!
        [ *command_prefix, *Array(command).map(&:to_s) ]
      end

      def close
        return true unless @runtime_root

        stat = File.lstat(@runtime_root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise SandboxError, "project evidence sandbox runtime ownership changed"
        end

        FileUtils.remove_entry_secure(@runtime_root)
        true
      rescue Errno::ENOENT
        true
      ensure
        @runtime_root = nil
        @writable_source_bindings = nil
      end

      private

      def validate_extra_environment!
        invalid = @extra_environment.any? do |key, value|
          !key.match?(/\A[A-Z][A-Z0-9_]*\z/) || value.to_s.include?("\0")
        end
        raise SandboxError, "project evidence sandbox environment is invalid" if invalid
      end

      def validate_overlay_root!
        stat = File.lstat(@runtime_overlay_root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise SandboxError, "project evidence sandbox overlay ownership is invalid"
        end
      end

      def prepare_runtime!
        return if @runtime_root
        unless @sandbox_binary && File.file?(@sandbox_binary) && File.executable?(@sandbox_binary)
          raise SandboxError, "project evidence sandbox requires bubblewrap"
        end

        @runtime_root = Dir.mktmpdir("hive-project-evidence-sandbox-")
        File.chmod(0o700, @runtime_root)
        %w[home tmp xdg/config xdg/cache xdg/data xdg/state].each do |relative|
          FileUtils.mkdir_p(File.join(@runtime_root, relative), mode: 0o700)
        end
      end

      def command_prefix
        bindings = writable_source_bindings
        parent_dirs = Hive::WorkflowPackage::RuntimePolicy.sandbox_parent_dirs(
          [ @source_root, @runtime_root, *runtime_mounts, *bindings.flatten ]
        )
        argv = [
          @sandbox_binary,
          "--die-with-parent", "--new-session", "--unshare-all"
        ]
        argv << "--share-net" if @share_network
        argv.concat([
          "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
          "--ro-bind", "/usr", "/usr",
          "--symlink", "usr/bin", "/bin", "--symlink", "usr/bin", "/sbin",
          "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64",
          "--dir", "/etc"
        ])
        %w[ssl resolv.conf hosts passwd group nsswitch.conf gai.conf].each do |relative|
          path = File.join("/etc", relative)
          argv.concat([ "--ro-bind", path, path ]) if File.exist?(path)
        end
        parent_dirs.each { |path| argv.concat([ "--dir", path ]) }
        runtime_mounts.each { |path| argv.concat([ "--ro-bind", path, path ]) }
        argv.concat([ "--ro-bind", @source_root, @source_root ])
        bindings.each { |overlay, target| argv.concat([ "--bind", overlay, target ]) }
        argv.concat([ "--bind", @runtime_root, @runtime_root ])
        sandbox_environment.each do |key, value|
          argv.concat([ "--setenv", key, value ])
        end
        argv.concat([ "--chdir", @source_root, "--" ])
      end

      def writable_source_dirs
        WRITABLE_SOURCE_DIRS.filter_map do |relative|
          path = File.join(@source_root, relative)
          next unless File.directory?(path) && !File.symlink?(path)

          real = File.realpath(path)
          real if real.start_with?("#{@source_root}#{File::SEPARATOR}")
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end
      end

      def writable_source_bindings
        @writable_source_bindings ||= writable_source_dirs.filter_map do |source|
          relative = source.delete_prefix("#{@source_root}#{File::SEPARATOR}")
          overlay = File.join(runtime_overlay_root, relative)
          seed_runtime_overlay(source, overlay)
          [ overlay, source ]
        end
      end

      def runtime_overlay_root
        root = @runtime_overlay_root || File.join(@runtime_root, "source-runtime")
        FileUtils.mkdir_p(root, mode: 0o700)
        validate_overlay_root! if @runtime_overlay_root
        root
      end

      def seed_runtime_overlay(source, overlay)
        return if File.directory?(overlay) && !File.symlink?(overlay)

        temporary = "#{overlay}.prepare-#{Process.pid}-#{Thread.current.object_id}"
        FileUtils.mkdir_p(temporary, mode: 0o700)
        entries = Dir.children(source).map { |entry| File.join(source, entry) }
        FileUtils.cp_r(entries, temporary, preserve: true) unless entries.empty?
        File.rename(temporary, overlay)
      rescue Errno::EEXIST, Errno::ENOTEMPTY
        FileUtils.remove_entry_secure(temporary) if File.directory?(temporary)
        raise unless File.directory?(overlay) && !File.symlink?(overlay)
      end

      def sandbox_environment
        safe = SAFE_ENVIRONMENT_KEYS.to_h { |key| [ key, @environment[key] ] }.compact
        safe.merge(
          "PATH" => [ File.dirname(ruby_executable), "/usr/local/bin", "/usr/bin", "/bin" ]
            .uniq.join(File::PATH_SEPARATOR),
          "HOME" => File.join(@runtime_root, "home"),
          "TMPDIR" => File.join(@runtime_root, "tmp"),
          "XDG_CONFIG_HOME" => File.join(@runtime_root, "xdg", "config"),
          "XDG_CACHE_HOME" => File.join(@runtime_root, "xdg", "cache"),
          "XDG_DATA_HOME" => File.join(@runtime_root, "xdg", "data"),
          "XDG_STATE_HOME" => File.join(@runtime_root, "xdg", "state"),
          "BUNDLE_USER_HOME" => File.join(@runtime_root, "home", ".bundle"),
          "GEM_HOME" => File.join(@runtime_root, "home", ".gem"),
          "GEM_PATH" => Gem.path.select { |path| File.directory?(path) }
            .map { |path| File.realpath(path) }.uniq.join(File::PATH_SEPARATOR)
        ).merge(@extra_environment.transform_values(&:to_s))
      end

      def runtime_mounts
        @runtime_mounts ||= begin
          paths = Gem.path.select { |path| File.directory?(path) }
          prefix = RbConfig::CONFIG["prefix"].to_s
          paths << prefix if File.directory?(prefix)
          paths.map { |path| File.realpath(path) }.uniq.reject do |path|
            path == "/usr" || path.start_with?("/usr/") ||
              path == @source_root || path.start_with?("#{@source_root}#{File::SEPARATOR}")
          end
        end
      end

      def ruby_executable
        @ruby_executable ||= File.realpath(RbConfig.ruby)
      end
    end
  end
end
