require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "securerandom"
require "tmpdir"
require "time"
require "hive"
require "hive/paths"

module Hive
  module Web
    # Installs Hive's pinned agent-browser native CLI and Chrome for Testing
    # into one lockfile-keyed cache. Capture callers use the native binary
    # directly; Node/npm are needed only to unpack the authenticated package.
    class BrowserBundle
      MANIFEST_SCHEMA = "hive-web-browser-bundle-v2".freeze
      MANIFEST_FILE = "manifest.json".freeze
      MIN_NODE_MAJOR = 18
      PACKAGE_ROOT = File.expand_path("../assets/capture-tools", __dir__).freeze

      class BootstrapError < Hive::Error; end
      class OwnershipError < BootstrapError; end

      Entry = Data.define(
        :cache_key, :cache_root, :agent_browser_cli, :browser_executable,
        :agent_browser_version, :browsers_path, :skills_path,
        :package_digests, :node_version, :platform
      )

      def initialize(source_root: nil, package_root: nil, cache_root: nil,
                     runner: nil, tool_probe: nil,
                     clock: -> { Time.now.utc }, environment: ENV)
        # source_root is accepted for call-site compatibility; capture tools
        # are deliberately shipped with Hive rather than borrowed from a task.
        @package_root = File.expand_path(package_root || PACKAGE_ROOT)
        @environment = environment.to_h
        @cache_root = File.expand_path(
          cache_root || @environment.fetch("HIVE_CAPTURE_TOOLS_CACHE", nil) ||
            File.join(Hive::Paths.data_home, "capture-tools")
        )
        @runner = runner || method(:default_runner)
        @tool_probe = tool_probe || method(:probe_tools!)
        @clock = clock
      end

      def ensure!
        node_version = @tool_probe.call
        package_state = package_state!
        key = cache_key(package_state, node_version)
        ensure_owned_directory!(@cache_root)
        with_cache_lock(key) do
          destination = File.join(@cache_root, key)
          cached = cache_entry(destination, key, package_state, node_version)
          return cached if cached

          quarantine!(destination)
          populate!(destination, key, package_state, node_version)
          cache_entry(destination, key, package_state, node_version) ||
            raise(BootstrapError, "populated capture cache did not validate")
        end
      end

      def cache_key(package_state = package_state!, node_version = @tool_probe.call)
        Digest::SHA256.hexdigest(JSON.generate(
          "schema" => MANIFEST_SCHEMA,
          "package" => package_state.fetch("package"),
          "package_lock" => package_state.fetch("package_lock"),
          "node_version" => node_version,
          "platform" => RbConfig::CONFIG.fetch("arch"),
          "native_binary" => native_binary_name
        ))
      end

      private

      def package_state!
        {
          "package" => package_digest(File.join(@package_root, "package.json")),
          "package_lock" => package_digest(File.join(@package_root, "package-lock.json"))
        }
      end

      def package_digest(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink?
          raise BootstrapError, "#{path} must be a regular package metadata file"
        end
        { "sha256" => Digest::SHA256.file(path).hexdigest, "mode" => stat.mode & 0o777 }
      rescue Errno::ENOENT
        raise BootstrapError, "required pinned capture dependency file is missing: #{path}"
      end

      def package_version
        document = JSON.parse(File.read(File.join(@package_root, "package.json")))
        version = document.dig("dependencies", "agent-browser").to_s
        unless version.match?(/\A\d+\.\d+\.\d+\z/)
          raise BootstrapError, "agent-browser must use one exact pinned version"
        end
        version
      rescue JSON::ParserError
        raise BootstrapError, "capture package metadata is invalid JSON"
      end

      def probe_tools!
        node_out, node_err, node_status = Open3.capture3(
          { "PATH" => @environment.fetch("PATH", "") }, "node", "--version"
        )
        unless node_status.success?
          raise BootstrapError, "Node.js is unavailable: #{node_err.to_s.strip}"
        end
        node_version = node_out.to_s.strip
        major = Integer(node_version[/\Av(\d+)/, 1], exception: false)
        unless major && major >= MIN_NODE_MAJOR
          raise BootstrapError,
                "Node.js #{MIN_NODE_MAJOR}+ is required to unpack capture tools; got #{node_version.inspect}"
        end
        node_version
      rescue Errno::ENOENT => e
        raise BootstrapError, "capture dependency tool is unavailable: #{e.message}"
      end

      def probe_npm!
        _npm_out, npm_err, npm_status = Open3.capture3(
          { "PATH" => @environment.fetch("PATH", "") }, "npm", "--version"
        )
        raise BootstrapError, "npm is unavailable: #{npm_err.to_s.strip}" unless npm_status.success?
      rescue Errno::ENOENT => e
        raise BootstrapError, "capture dependency tool is unavailable: #{e.message}"
      end

      def ensure_owned_directory!(path)
        FileUtils.mkdir_p(path, mode: 0o700)
        stat = File.lstat(path)
        raise OwnershipError, "capture cache must not be a symlink: #{path}" if stat.symlink?
        raise OwnershipError, "capture cache is not a directory: #{path}" unless stat.directory?
        unless stat.uid == Process.uid
          raise OwnershipError, "capture cache is owned by uid #{stat.uid}, expected #{Process.uid}: #{path}"
        end
        FileUtils.chmod(0o700, path)
      end

      def with_cache_lock(key)
        lock_path = File.join(@cache_root, ".#{key}.lock")
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(lock_path, flags, 0o600) do |lock|
          raise OwnershipError, "capture cache lock must be a regular file" unless lock.stat.file?
          raise OwnershipError, "capture cache lock has foreign ownership" unless lock.stat.uid == Process.uid
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise OwnershipError, "capture cache lock must not be a symlink"
      end

      def populate!(destination, key, package_state, node_version)
        staging = Dir.mktmpdir(".#{key}.populate-", @cache_root)
        node_root = File.join(staging, "node")
        npm_cache = File.join(staging, "npm-cache")
        home = File.join(staging, "browser-home")
        browsers_path = File.join(home, ".agent-browser", "browsers")
        FileUtils.mkdir_p([ node_root, browsers_path, npm_cache, home ], mode: 0o700)
        before = package_snapshots
        %w[package.json package-lock.json].each do |name|
          FileUtils.cp(File.join(@package_root, name), File.join(node_root, name), preserve: true)
        end
        env = browser_environment(home:, browsers_path:, npm_cache:)
        probe_npm!
        installed = @runner.call(
          %w[npm ci --ignore-scripts --no-audit --no-fund], env, chdir: node_root
        )
        raise BootstrapError, "pinned agent-browser npm install failed" unless installed

        cli = native_cli(node_root)
        unless File.file?(cli)
          raise BootstrapError, "pinned agent-browser native CLI was not installed"
        end
        FileUtils.chmod(0o700, cli)
        install_argv = [ cli, "install" ]
        install_argv << "--with-deps" if @environment["HIVE_CAPTURE_INSTALL_WITH_DEPS"] == "1"
        browser_installed = @runner.call(install_argv, env, chdir: node_root)
        raise BootstrapError, "managed Chrome for Testing install failed" unless browser_installed
        browser_executable = populated_browser_executable(browsers_path)
        unless browser_executable
          raise BootstrapError, "agent-browser reported success without a managed Chrome payload"
        end
        assert_packages_unchanged!(before)
        write_json_atomic(
          File.join(staging, MANIFEST_FILE),
          manifest_document(
            key, package_state, node_version,
            browser_executable: Pathname.new(browser_executable)
              .relative_path_from(Pathname.new(staging)).to_s
          )
        )
        FileUtils.rm_rf(npm_cache)
        seal_cache!(staging)
        File.rename(staging, destination)
      rescue BootstrapError
        raise
      rescue SystemCallError => e
        raise BootstrapError, "capture cache population failed: #{e.message}"
      ensure
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
      end

      def browser_environment(home:, browsers_path:, npm_cache:)
        {
          "PATH" => @environment.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
          "LANG" => @environment["LANG"], "LC_ALL" => @environment["LC_ALL"],
          "LC_CTYPE" => @environment["LC_CTYPE"],
          "SSL_CERT_FILE" => @environment["SSL_CERT_FILE"],
          "SSL_CERT_DIR" => @environment["SSL_CERT_DIR"],
          "DEBIAN_FRONTEND" => @environment["DEBIAN_FRONTEND"],
          "HOME" => home,
          "XDG_CONFIG_HOME" => File.join(home, ".config"),
          "XDG_CACHE_HOME" => File.join(home, ".cache"),
          "PUPPETEER_CACHE_DIR" => browsers_path,
          "npm_config_cache" => npm_cache,
          "npm_config_update_notifier" => "false",
          "npm_config_fund" => "false", "npm_config_audit" => "false",
          "NODE_OPTIONS" => nil, "NODE_PATH" => nil,
          "NPM_CONFIG_USERCONFIG" => File::NULL
        }.compact
      end

      def default_runner(argv, env, chdir:)
        system(
          env, *argv, chdir: chdir, in: File::NULL, out: $stderr, err: $stderr,
          unsetenv_others: true
        )
      end

      def cache_entry(destination, key, package_state, node_version)
        stat = File.lstat(destination)
        raise OwnershipError, "capture cache entry must not be a symlink" if stat.symlink?
        return unless stat.directory?
        raise OwnershipError, "capture cache entry has foreign ownership" unless stat.uid == Process.uid
        document = JSON.parse(File.read(File.join(destination, MANIFEST_FILE)))
        relative_browser = document["browser_executable"]
        expected = manifest_document(
          key, package_state, node_version, browser_executable: relative_browser
        )
        return unless document == expected

        cli = native_cli(File.join(destination, "node"))
        return unless File.file?(cli) && File.executable?(cli)
        browser_executable = cached_browser_executable(destination, relative_browser)
        return unless browser_executable
        entry(
          destination, key, package_state, node_version,
          browser_executable: browser_executable
        )
      rescue JSON::ParserError, Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def native_cli(node_root)
        File.join(node_root, "node_modules", "agent-browser", "bin", native_binary_name)
      end

      def native_binary_name
        os = RbConfig::CONFIG.fetch("host_os")
        cpu = RbConfig::CONFIG.fetch("host_cpu")
        arch = case cpu
        when /(?:aarch64|arm64)/i then "arm64"
        when /(?:x86_64|amd64)/i then "x64"
        else
          raise BootstrapError, "agent-browser does not support #{os}/#{cpu}"
        end
        return "agent-browser-win32-x64.exe" if os.match?(/mswin|mingw|cygwin/i)
        return "agent-browser-darwin-#{arch}" if os.match?(/darwin/i)
        if os.match?(/linux/i)
          libc = RUBY_PLATFORM.include?("musl") ? "-musl" : ""
          return "agent-browser-linux#{libc}-#{arch}"
        end
        raise BootstrapError, "agent-browser does not support #{os}/#{cpu}"
      end

      def populated_browser_executable(path)
        return unless File.directory?(path)
        names = RbConfig::CONFIG.fetch("host_os").match?(/mswin|mingw|cygwin/i) ?
          %w[chrome.exe] : %w[chrome chrome-headless-shell]
        candidates = names.flat_map { |name| Dir.glob(File.join(path, "**", name)) }
        candidates.sort.find { |candidate| File.file?(candidate) && !File.symlink?(candidate) }
      rescue SystemCallError
        nil
      end

      def cached_browser_executable(root, relative)
        path = Pathname.new(relative.to_s)
        unless !path.absolute? && path.cleanpath.to_s == relative &&
               path.each_filename.none? { |part| part == ".." }
          raise OwnershipError, "capture cache browser executable path is invalid"
        end
        candidate = File.join(root, relative)
        stat = File.lstat(candidate)
        unless stat.file? && !stat.symlink? && stat.uid == Process.uid && File.executable?(candidate)
          raise OwnershipError, "capture cache browser executable is invalid"
        end
        root_real = File.realpath(root)
        candidate_real = File.realpath(candidate)
        unless candidate_real.start_with?("#{root_real}#{File::SEPARATOR}")
          raise OwnershipError, "capture cache browser executable escapes its cache"
        end
        candidate_real
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        nil
      end

      def browser_path(root)
        File.join(root, "browser-home", ".agent-browser", "browsers")
      end

      def quarantine!(destination)
        stat = File.lstat(destination)
        if stat.symlink?
          raise OwnershipError, "capture cache entry must not be a symlink: #{destination}"
        end
        unless stat.uid == Process.uid
          raise OwnershipError, "capture cache entry has foreign ownership: #{destination}"
        end
        suffix = "#{@clock.call.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
        File.rename(destination, "#{destination}.corrupt-#{suffix}")
      rescue Errno::ENOENT
        nil
      end

      def manifest_document(key, package_state, node_version, browser_executable:)
        {
          "schema" => MANIFEST_SCHEMA, "cache_key" => key,
          "package_digests" => package_state, "node_version" => node_version,
          "platform" => RbConfig::CONFIG.fetch("arch"),
          "native_binary" => native_binary_name,
          "agent_browser_version" => package_version,
          "browser_executable" => browser_executable
        }
      end

      def entry(destination, key, package_state, node_version, browser_executable:)
        node_root = File.join(destination, "node")
        Entry.new(
          cache_key: key, cache_root: destination,
          agent_browser_cli: native_cli(node_root),
          browser_executable: browser_executable,
          agent_browser_version: package_version,
          browsers_path: browser_path(destination),
          skills_path: File.join(node_root, "node_modules", "agent-browser", "skill-data"),
          package_digests: package_state.transform_values { |value| value.fetch("sha256") },
          node_version: node_version, platform: RbConfig::CONFIG.fetch("arch")
        )
      end

      def package_snapshots
        %w[package.json package-lock.json].to_h do |name|
          path = File.join(@package_root, name)
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
              raise OwnershipError, "capture cache contains an escaping symlink: #{path}"
            end
          else
            raise OwnershipError, "capture cache population produced unsupported entry: #{path}"
          end
        end
      end
    end
  end
end
