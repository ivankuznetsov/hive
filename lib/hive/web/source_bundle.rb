require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "rbconfig"
require "rubygems"
require "securerandom"
require "tmpdir"
require "time"
require "hive"
require "hive/paths"

module Hive
  module Web
    # Installs the Rails bundle needed by capture into a shared immutable cache
    # outside the linked source worktree. Cache identity includes both lockfiles
    # and the exact Ruby/platform tuple; population is serialized and published
    # by rename so another worktree never observes a partial install.
    class SourceBundle
      MANIFEST_SCHEMA = "hive-web-source-bundle-v1".freeze
      MANIFEST_FILE = "manifest.json".freeze

      class BootstrapError < Hive::Error; end
      class OwnershipError < BootstrapError; end

      Entry = Data.define(
        :cache_key, :cache_root, :bundle_path, :source_sha, :lock_digests,
        :ruby_engine, :ruby_version, :platform
      )

      def initialize(source_root:, cache_root: nil, runner: nil, source_validator: nil,
                     clock: -> { Time.now.utc }, environment: ENV)
        @source_root = File.expand_path(source_root)
        @cache_root = File.expand_path(cache_root || File.join(Hive::Paths.data_home, "web-capture-bundles"))
        @runner = runner || method(:default_runner)
        @source_validator = source_validator || method(:validate_source!)
        @clock = clock
        @environment = environment.to_h
      end

      def ensure!
        source_sha = @source_validator.call(@source_root)
        lock_state = lock_state!
        key = cache_key(lock_state)
        ensure_owned_directory!(@cache_root)
        with_cache_lock(key) do
          destination = File.join(@cache_root, key)
          return entry(destination, key, source_sha, lock_state) if cache_valid?(destination, key, lock_state)

          quarantine!(destination) if File.exist?(destination) || File.symlink?(destination)
          populate!(destination, key, source_sha, lock_state)
          entry(destination, key, source_sha, lock_state)
        end
      end

      def cache_key(lock_state = lock_state!)
        ::Digest::SHA256.hexdigest(JSON.generate(
          "schema" => MANIFEST_SCHEMA,
          "root_lock" => lock_state.fetch("root"),
          "web_lock" => lock_state.fetch("web"),
          "ruby_engine" => RUBY_ENGINE,
          "ruby_version" => RUBY_VERSION,
          "platform" => RbConfig::CONFIG.fetch("arch")
        ))
      end

      private

      def lock_state!
        {
          "root" => lock_digest(File.join(@source_root, "Gemfile.lock")),
          "web" => lock_digest(File.join(@source_root, "web", "Gemfile.lock"))
        }
      end

      def lock_digest(path)
        stat = File.lstat(path)
        raise BootstrapError, "#{path} must be a regular lockfile" unless stat.file? && !stat.symlink?

        {
          "sha256" => ::Digest::SHA256.file(path).hexdigest,
          "mode" => stat.mode & 0o777
        }
      rescue Errno::ENOENT
        raise BootstrapError, "required locked web dependency file is missing: #{path}"
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

      def populate!(destination, key, source_sha, lock_state)
        staging = Dir.mktmpdir(".#{key}.populate-", @cache_root)
        bundle_path = File.join(staging, "gems")
        app_config = File.join(staging, "bundler")
        FileUtils.mkdir_p([ bundle_path, app_config ], mode: 0o700)
        before = lockfile_snapshots
        env = {
          "PATH" => @environment.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
          "LANG" => @environment["LANG"],
          "LC_ALL" => @environment["LC_ALL"],
          "SSL_CERT_FILE" => @environment["SSL_CERT_FILE"],
          "SSL_CERT_DIR" => @environment["SSL_CERT_DIR"],
          "BUNDLE_GEMFILE" => File.join(@source_root, "web", "Gemfile"),
          "BUNDLE_PATH" => bundle_path,
          "BUNDLE_APP_CONFIG" => app_config,
          "BUNDLE_FROZEN" => "1",
          "BUNDLE_DEPLOYMENT" => "1",
          "BUNDLE_DISABLE_SHARED_GEMS" => "1",
          "BUNDLE_USER_HOME" => File.join(staging, "home", ".bundle"),
          "GEM_HOME" => nil,
          "GEM_PATH" => nil,
          "HIVE_CLI_ROOT" => @source_root,
          "RUBYOPT" => nil,
          "RUBYLIB" => nil
        }.compact
        ok = @runner.call(bundle_install_argv, env, chdir: File.join(@source_root, "web"))
        raise BootstrapError, "locked web bundle install failed (dependency may be unavailable offline)" unless ok
        assert_lockfiles_unchanged!(before)

        manifest = manifest_document(key, source_sha, lock_state)
        write_json_atomic(File.join(staging, MANIFEST_FILE), manifest)
        seal_cache!(staging)
        File.rename(staging, destination)
      rescue BootstrapError
        raise
      rescue SystemCallError => e
        raise BootstrapError, "capture cache population failed: #{e.message}"
      ensure
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
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

      def bundle_install_argv
        version = locked_bundler_version
        executable = Gem.bin_path("bundler", "bundle", "= #{version}")
        unless File.file?(executable)
          raise BootstrapError, "locked Bundler #{version} executable is unavailable"
        end

        [ RbConfig.ruby, executable, "install", "--jobs", "4", "--retry", "2" ]
      rescue Gem::GemNotFoundException
        raise BootstrapError,
              "locked Bundler #{version} is unavailable; install Bundler #{version} before capture"
      end

      def locked_bundler_version
        lockfile = File.join(@source_root, "web", "Gemfile.lock")
        version = File.read(lockfile)[/^BUNDLED WITH\s*\n\s+(\S+)\s*$/m, 1].to_s
        unless version.match?(/\A\d+(?:\.\d+){1,3}(?:[.-][0-9A-Za-z]+)*\z/)
          raise BootstrapError, "#{lockfile} has no valid BUNDLED WITH version"
        end

        version
      rescue Errno::ENOENT
        raise BootstrapError, "required locked web dependency file is missing: #{lockfile}"
      end

      def cache_valid?(destination, key, lock_state)
        return false unless File.directory?(destination)
        stat = File.lstat(destination)
        raise OwnershipError, "capture cache entry must not be a symlink" if stat.symlink?
        raise OwnershipError, "capture cache entry has foreign ownership" unless stat.uid == Process.uid

        document = JSON.parse(File.read(File.join(destination, MANIFEST_FILE)))
        expected = manifest_document(key, document["source_sha"], lock_state)
        document == expected && File.directory?(File.join(destination, "gems"))
      rescue JSON::ParserError, Errno::ENOENT, Errno::ENOTDIR
        false
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
      end

      def manifest_document(key, source_sha, lock_state)
        {
          "schema" => MANIFEST_SCHEMA,
          "cache_key" => key,
          "source_sha" => source_sha,
          "lock_digests" => lock_state,
          "ruby_engine" => RUBY_ENGINE,
          "ruby_version" => RUBY_VERSION,
          "platform" => RbConfig::CONFIG.fetch("arch")
        }
      end

      def entry(destination, key, source_sha, lock_state)
        Entry.new(
          cache_key: key,
          cache_root: destination,
          bundle_path: File.join(destination, "gems"),
          source_sha: source_sha,
          lock_digests: lock_state.transform_values { |value| value.fetch("sha256") },
          ruby_engine: RUBY_ENGINE,
          ruby_version: RUBY_VERSION,
          platform: RbConfig::CONFIG.fetch("arch")
        )
      end

      def lockfile_snapshots
        %w[Gemfile.lock web/Gemfile.lock].to_h do |relative|
          path = File.join(@source_root, relative)
          [ path, [ File.binread(path), File.stat(path).mode & 0o777 ] ]
        end
      end

      def assert_lockfiles_unchanged!(before)
        changed = before.filter_map do |path, (bytes, mode)|
          path unless File.binread(path) == bytes && (File.stat(path).mode & 0o777) == mode
        end
        return if changed.empty?

        raise BootstrapError, "Bundler changed authenticated lockfile(s): #{changed.join(', ')}"
      end

      def validate_source!(root)
        stat = File.lstat(root)
        raise OwnershipError, "source worktree must not be a symlink" if stat.symlink?
        raise OwnershipError, "source worktree has foreign ownership" unless stat.uid == Process.uid

        top, err, status = Open3.capture3(
          { "GIT_CONFIG_NOSYSTEM" => "1" },
          "git", "-C", root, "rev-parse", "--show-toplevel"
        )
        raise BootstrapError, "source is not a Git worktree: #{err.strip}" unless status.success?
        unless File.realpath(top.strip) == File.realpath(root)
          raise BootstrapError, "source root does not match the Git worktree top level"
        end

        head, head_err, head_status = Open3.capture3(
          { "GIT_CONFIG_NOSYSTEM" => "1" },
          "git", "-C", root, "rev-parse", "HEAD"
        )
        raise BootstrapError, "source HEAD is unavailable: #{head_err.strip}" unless head_status.success?
        sha = head.strip
        raise BootstrapError, "source HEAD is invalid" unless sha.match?(/\A[0-9a-f]{40,64}\z/)

        dirty, dirty_err, dirty_status = Open3.capture3(
          { "GIT_CONFIG_NOSYSTEM" => "1" },
          "git", "-C", root, "status", "--porcelain=v1", "--untracked-files=normal"
        )
        raise BootstrapError, "source cleanliness check failed: #{dirty_err.strip}" unless dirty_status.success?
        raise BootstrapError, "source worktree is dirty; capture requires an exact clean HEAD" unless dirty.empty?

        sha
      rescue Errno::ENOENT, Errno::ENOTDIR => e
        raise BootstrapError, "source worktree is unavailable: #{e.message}"
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
        Find.find(root) do |path|
          stat = File.lstat(path)
          if stat.directory?
            # Keep directories owner-writable so the cache owner can
            # quarantine/remove an entry; payload files themselves are sealed
            # read-only and every reuse verifies the manifest.
            File.chmod(0o700, path)
          elsif stat.file?
            executable = (stat.mode & 0o111).positive?
            File.chmod(executable ? 0o500 : 0o400, path)
          else
            raise OwnershipError, "capture cache population produced unsupported entry: #{path}"
          end
        end
      end
    end
  end
end
