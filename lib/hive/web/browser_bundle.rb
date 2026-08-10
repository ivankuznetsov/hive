require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"
require "time"
require "hive"
require "hive/paths"

module Hive
  module Web
    # Installs the pinned Playwright package and its Chromium payload into a
    # shared, lockfile-keyed cache. A linked worktree therefore needs neither
    # node_modules nor a browser download of its own.
    class BrowserBundle
      MANIFEST_SCHEMA = "hive-web-browser-bundle-v1".freeze
      MANIFEST_FILE = "manifest.json".freeze
      MIN_NODE_MAJOR = 22

      class BootstrapError < Hive::Error; end
      class OwnershipError < BootstrapError; end

      Entry = Data.define(
        :cache_key, :cache_root, :node_modules_path, :playwright_cli,
        :browsers_path, :package_digests, :node_version, :platform
      )

      def initialize(source_root:, cache_root: nil, runner: nil,
                     tool_probe: nil, clock: -> { Time.now.utc },
                     environment: ENV)
        @source_root = File.expand_path(source_root)
        @cache_root = File.expand_path(
          cache_root || File.join(Hive::Paths.data_home, "web-capture-browsers")
        )
        @runner = runner || method(:default_runner)
        @tool_probe = tool_probe || method(:probe_tools!)
        @clock = clock
        @environment = environment.to_h
      end

      def ensure!
        node_version = @tool_probe.call
        package_state = package_state!
        key = cache_key(package_state, node_version)
        ensure_owned_directory!(@cache_root)
        with_cache_lock(key) do
          destination = File.join(@cache_root, key)
          if cache_valid?(destination, key, package_state, node_version)
            return entry(destination, key, package_state, node_version)
          end

          quarantine!(destination) if File.exist?(destination) || File.symlink?(destination)
          populate!(destination, key, package_state, node_version)
          entry(destination, key, package_state, node_version)
        end
      end

      def cache_key(package_state = package_state!, node_version = @tool_probe.call)
        ::Digest::SHA256.hexdigest(JSON.generate(
          "schema" => MANIFEST_SCHEMA,
          "package" => package_state.fetch("package"),
          "package_lock" => package_state.fetch("package_lock"),
          "node_version" => node_version,
          "platform" => RbConfig::CONFIG.fetch("arch")
        ))
      end

      private

      def package_state!
        {
          "package" => package_digest(File.join(@source_root, "web", "package.json")),
          "package_lock" => package_digest(File.join(@source_root, "web", "package-lock.json"))
        }
      end

      def package_digest(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink?
          raise BootstrapError, "#{path} must be a regular package metadata file"
        end

        {
          "sha256" => ::Digest::SHA256.file(path).hexdigest,
          "mode" => stat.mode & 0o777
        }
      rescue Errno::ENOENT
        raise BootstrapError, "required pinned browser dependency file is missing: #{path}"
      end

      def probe_tools!
        node_out, node_err, node_status = Open3.capture3(
          { "PATH" => @environment.fetch("PATH", "") },
          "node", "--version"
        )
        unless node_status.success?
          raise BootstrapError, "Node.js is unavailable: #{node_err.to_s.strip}"
        end
        node_version = node_out.to_s.strip
        major = Integer(node_version[/\Av(\d+)/, 1], exception: false)
        unless major && major >= MIN_NODE_MAJOR
          raise BootstrapError,
                "Node.js #{MIN_NODE_MAJOR}+ is required for pinned Playwright; got #{node_version.inspect}"
        end

        _npm_out, npm_err, npm_status = Open3.capture3(
          { "PATH" => @environment.fetch("PATH", "") },
          "npm", "--version"
        )
        raise BootstrapError, "npm is unavailable: #{npm_err.to_s.strip}" unless npm_status.success?

        node_version
      rescue Errno::ENOENT => e
        raise BootstrapError, "browser dependency tool is unavailable: #{e.message}"
      end

      def ensure_owned_directory!(path)
        FileUtils.mkdir_p(path, mode: 0o700)
        stat = File.lstat(path)
        raise OwnershipError, "browser cache must not be a symlink: #{path}" if stat.symlink?
        raise OwnershipError, "browser cache is not a directory: #{path}" unless stat.directory?
        unless stat.uid == Process.uid
          raise OwnershipError, "browser cache is owned by uid #{stat.uid}, expected #{Process.uid}: #{path}"
        end
        FileUtils.chmod(0o700, path)
      end

      def with_cache_lock(key)
        lock_path = File.join(@cache_root, ".#{key}.lock")
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(lock_path, flags, 0o600) do |lock|
          raise OwnershipError, "browser cache lock must be a regular file" unless lock.stat.file?
          raise OwnershipError, "browser cache lock has foreign ownership" unless lock.stat.uid == Process.uid

          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise OwnershipError, "browser cache lock must not be a symlink"
      end

      def populate!(destination, key, package_state, node_version)
        staging = Dir.mktmpdir(".#{key}.populate-", @cache_root)
        node_root = File.join(staging, "node")
        browsers_path = File.join(staging, "browsers")
        npm_cache = File.join(staging, "npm-cache")
        home = File.join(staging, "home")
        FileUtils.mkdir_p([ node_root, browsers_path, npm_cache, home ], mode: 0o700)
        source_package = File.join(@source_root, "web", "package.json")
        source_lock = File.join(@source_root, "web", "package-lock.json")
        before = package_snapshots
        FileUtils.cp(source_package, File.join(node_root, "package.json"), preserve: true)
        FileUtils.cp(source_lock, File.join(node_root, "package-lock.json"), preserve: true)
        env = browser_environment(
          home: home, browsers_path: browsers_path, npm_cache: npm_cache
        )
        installed = @runner.call(
          %w[npm ci --ignore-scripts --no-audit --no-fund],
          env,
          chdir: node_root
        )
        raise BootstrapError, "pinned Playwright npm install failed" unless installed

        cli = File.join(node_root, "node_modules", ".bin", "playwright")
        unless File.file?(cli) && File.executable?(cli)
          raise BootstrapError, "pinned Playwright CLI was not installed"
        end
        browser_installed = @runner.call(
          [ cli, "install", "chromium" ],
          env,
          chdir: node_root
        )
        raise BootstrapError, "pinned Playwright Chromium install failed" unless browser_installed
        unless populated_browser_cache?(browsers_path)
          raise BootstrapError, "Playwright reported success without a Chromium payload"
        end
        assert_packages_unchanged!(before)

        write_json_atomic(
          File.join(staging, MANIFEST_FILE),
          manifest_document(key, package_state, node_version)
        )
        FileUtils.rm_rf(npm_cache)
        FileUtils.rm_rf(home)
        seal_cache!(staging)
        File.rename(staging, destination)
      rescue BootstrapError
        raise
      rescue SystemCallError => e
        raise BootstrapError, "browser cache population failed: #{e.message}"
      ensure
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
      end

      def browser_environment(home:, browsers_path:, npm_cache:)
        {
          "PATH" => @environment.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
          "LANG" => @environment["LANG"],
          "LC_ALL" => @environment["LC_ALL"],
          "LC_CTYPE" => @environment["LC_CTYPE"],
          "SSL_CERT_FILE" => @environment["SSL_CERT_FILE"],
          "SSL_CERT_DIR" => @environment["SSL_CERT_DIR"],
          "HOME" => home,
          "XDG_CONFIG_HOME" => File.join(home, ".config"),
          "XDG_CACHE_HOME" => File.join(home, ".cache"),
          "npm_config_cache" => npm_cache,
          "npm_config_update_notifier" => "false",
          "npm_config_fund" => "false",
          "npm_config_audit" => "false",
          "PLAYWRIGHT_BROWSERS_PATH" => browsers_path,
          "NODE_OPTIONS" => nil,
          "NODE_PATH" => nil,
          "NPM_CONFIG_USERCONFIG" => File::NULL
        }.compact
      end

      def default_runner(argv, env, chdir:)
        system(
          env,
          *argv,
          chdir: chdir,
          in: File::NULL,
          out: $stderr,
          err: $stderr,
          unsetenv_others: true
        )
      end

      def cache_valid?(destination, key, package_state, node_version)
        return false unless File.directory?(destination)
        stat = File.lstat(destination)
        raise OwnershipError, "browser cache entry must not be a symlink" if stat.symlink?
        raise OwnershipError, "browser cache entry has foreign ownership" unless stat.uid == Process.uid

        document = JSON.parse(File.read(File.join(destination, MANIFEST_FILE)))
        return false unless document == manifest_document(key, package_state, node_version)

        cli = File.join(destination, "node", "node_modules", ".bin", "playwright")
        File.file?(cli) && File.executable?(cli) &&
          populated_browser_cache?(File.join(destination, "browsers"))
      rescue JSON::ParserError, Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def populated_browser_cache?(path)
        File.directory?(path) &&
          Dir.children(path).any? { |name| name.start_with?("chromium-") }
      rescue SystemCallError
        false
      end

      def quarantine!(destination)
        stat = File.lstat(destination)
        if stat.symlink?
          raise OwnershipError, "browser cache entry must not be a symlink: #{destination}"
        end
        unless stat.uid == Process.uid
          raise OwnershipError, "browser cache entry has foreign ownership: #{destination}"
        end

        suffix = "#{@clock.call.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
        File.rename(destination, "#{destination}.corrupt-#{suffix}")
      end

      def manifest_document(key, package_state, node_version)
        {
          "schema" => MANIFEST_SCHEMA,
          "cache_key" => key,
          "package_digests" => package_state,
          "node_version" => node_version,
          "platform" => RbConfig::CONFIG.fetch("arch")
        }
      end

      def entry(destination, key, package_state, node_version)
        node_root = File.join(destination, "node")
        Entry.new(
          cache_key: key,
          cache_root: destination,
          node_modules_path: File.join(node_root, "node_modules"),
          playwright_cli: File.join(node_root, "node_modules", ".bin", "playwright"),
          browsers_path: File.join(destination, "browsers"),
          package_digests: package_state.transform_values { |value| value.fetch("sha256") },
          node_version: node_version,
          platform: RbConfig::CONFIG.fetch("arch")
        )
      end

      def package_snapshots
        %w[web/package.json web/package-lock.json].to_h do |relative|
          path = File.join(@source_root, relative)
          [ path, [ File.binread(path), File.stat(path).mode & 0o777 ] ]
        end
      end

      def assert_packages_unchanged!(before)
        changed = before.filter_map do |path, (bytes, mode)|
          path unless File.binread(path) == bytes && (File.stat(path).mode & 0o777) == mode
        end
        return if changed.empty?

        raise BootstrapError, "npm changed authenticated package metadata: #{changed.join(', ')}"
      end

      def write_json_atomic(path, document)
        tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{JSON.generate(document)}\n")
          file.flush
          file.fsync
        end
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      def seal_cache!(root)
        root_real = File.realpath(root)
        Find.find(root) do |path|
          stat = File.lstat(path)
          if stat.directory?
            File.chmod(0o700, path)
          elsif stat.file?
            executable = (stat.mode & 0o111).positive?
            File.chmod(executable ? 0o500 : 0o400, path)
          elsif stat.symlink?
            target = File.realpath(path)
            unless target == root_real || target.start_with?("#{root_real}#{File::SEPARATOR}")
              raise OwnershipError, "browser cache contains an escaping symlink: #{path}"
            end
          else
            raise OwnershipError, "browser cache population produced unsupported entry: #{path}"
          end
        end
      end
    end
  end
end
