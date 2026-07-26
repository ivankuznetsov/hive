require "digest"
require "fileutils"
require "json"
require "open3"
require "open-uri"
require "rbconfig"
require "rubygems/package"
require "securerandom"
require "tmpdir"
require "zlib"

require "hive"
require "hive/invoked_binary"
require "hive/paths"

module Hive
  module Web
    module AppBundle
      VERSION_FILE = ".hive-web-version".freeze
      REFRESH_LOCK_FILE = ".hive-web-refresh.lock".freeze
      REQUIRED_ASSETS = %w[application.css application.js].freeze
      COSIGN_TIMEOUT_SEC = 60

      module_function

      def app_dir
        Hive::Paths.web_app_home
      end

      # Root of the hive-cli gem this code is running from. The managed
      # bundle's Gemfile resolves `gem "hive-cli"` through HIVE_CLI_ROOT
      # (there is no gem at its `..`, and hive-cli is not on rubygems), so
      # every bundler/Rails invocation against the managed app must export
      # this. Works identically for an installed gem and a source checkout.
      def hive_cli_root
        File.expand_path("../../..", __dir__)
      end

      def present?
        File.file?(File.join(app_dir, "config", "application.rb"))
      end

      def installed_version
        path = File.join(app_dir, VERSION_FILE)
        File.read(path).strip if File.file?(path)
      end

      def stale?
        present? && installed_version != Hive::VERSION
      end

      def assets_ready?(dir = app_dir)
        assets_dir = File.join(dir, "public", "assets")
        assets_root = File.expand_path(assets_dir)
        manifest = JSON.parse(File.read(File.join(assets_dir, ".manifest.json")))
        return false unless manifest.is_a?(Hash)
        return false unless REQUIRED_ASSETS.all? { |logical_path| manifest.key?(logical_path) }

        manifest.values.all? do |entry|
          digested_path = entry["digested_path"] if entry.is_a?(Hash)
          next false unless digested_path.is_a?(String) && !digested_path.empty?

          asset_path = File.expand_path(digested_path, assets_dir)
          asset_path.start_with?("#{assets_root}/") && File.file?(asset_path)
        end
      rescue ArgumentError, JSON::ParserError, SystemCallError, TypeError
        false
      end

      def ensure!(bundle_url: default_bundle_url, bundle_sha256: default_bundle_sha256,
                  runner: nil, output: $stderr, downloader: nil, verifier: nil,
                  force_refresh: false, renamer: nil)
        with_refresh_lock do
          return app_dir if !force_refresh && present? && !stale? && assets_ready?

          if bundle_url.to_s.empty?
            raise Hive::Error,
                  "hive web: managed web app is missing. Set HIVE_WEB_BUNDLE_URL or run from a source checkout."
          end

          tmp = "#{app_dir}.tmp.#{Process.pid}.#{SecureRandom.hex(6)}"
          FileUtils.mkdir_p(tmp)
          fetch_and_extract(
            bundle_url, tmp,
            bundle_sha256: bundle_sha256,
            downloader: downloader,
            verifier: verifier
          )
          unless File.file?(File.join(tmp, "config", "application.rb"))
            nested = Dir.children(tmp).map { |child| File.join(tmp, child) }
                        .find { |path| File.file?(File.join(path, "config", "application.rb")) }
            if nested
              Dir.children(nested).each { |child| FileUtils.mv(File.join(nested, child), tmp) }
            end
          end
          unless File.file?(File.join(tmp, "config", "application.rb"))
            raise Hive::Error, "hive web: downloaded web bundle does not contain config/application.rb"
          end

          # Prepare and stamp the staged bundle before activation. The current
          # generation is retained as a sibling backup until the staged rename
          # succeeds, and any activation failure restores it.
          prepare!(dir: tmp, runner: runner, output: output)
          File.write(File.join(tmp, VERSION_FILE), "#{Hive::VERSION}\n")
          activate!(tmp, renamer: renamer)
        ensure
          FileUtils.rm_rf(tmp) if tmp
        end
      end

      def with_refresh_lock
        parent = File.dirname(app_dir)
        FileUtils.mkdir_p(parent)
        path = File.join(parent, REFRESH_LOCK_FILE)
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end

      def activate!(staged_dir, renamer: nil)
        renamer ||= File.method(:rename)
        backup = "#{app_dir}.backup.#{Process.pid}.#{SecureRandom.hex(6)}"
        previous_moved = false
        activated = false

        begin
          if File.exist?(app_dir) || File.symlink?(app_dir)
            renamer.call(app_dir, backup)
            previous_moved = true
          end
          renamer.call(staged_dir, app_dir)
          activated = true
        rescue StandardError => activation_error
          begin
            if previous_moved && (File.exist?(backup) || File.symlink?(backup))
              FileUtils.rm_rf(app_dir) if File.exist?(app_dir) || File.symlink?(app_dir)
              renamer.call(backup, app_dir)
              previous_moved = false
            end
          rescue StandardError => rollback_error
            raise Hive::Error,
                  "hive web: could not activate prepared web bundle " \
                  "(#{activation_error.class}: #{activation_error.message}); " \
                  "rollback failed (#{rollback_error.class}: #{rollback_error.message})"
          end
          raise Hive::Error,
                "hive web: could not activate prepared web bundle " \
                "(#{activation_error.class}: #{activation_error.message})"
        ensure
          FileUtils.rm_rf(backup) if activated && previous_moved
        end

        app_dir
      end

      def bundle_install!(dir: app_dir, runner: nil, output: $stderr)
        unless File.file?(File.join(dir, "Gemfile"))
          raise Hive::Error, "hive web: downloaded web bundle does not contain a Gemfile"
        end

        unless File.file?(File.join(hive_cli_root, "hive.gemspec"))
          raise Hive::Error,
                "hive web: installed hive-cli root #{hive_cli_root} has no hive.gemspec; " \
                "reinstall the hive-cli package before provisioning Hive web"
        end

        command = runner ? %w[bundle install] : bundle_install_argv(dir)
        runner ||= default_runner(output)
        lockfile = File.join(dir, "Gemfile.lock")
        # Bundler rewrites a relative path source (`remote: ..`) to the
        # installed gem's absolute HIVE_CLI_ROOT. That machine-local path is
        # not application state and would make the activated app differ from
        # the authenticated release archive. Preserve the tracked lockfile
        # bytes/mode while still letting Bundler resolve and install against
        # the real packaged gem root.
        lockfile_bytes = File.binread(lockfile) if File.file?(lockfile)
        lockfile_mode = File.stat(lockfile).mode & 0o777 if lockfile_bytes
        env = {
          "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"),
          "BUNDLE_PATH" => dependency_dir,
          "GEM_HOME" => nil,
          "GEM_PATH" => nil,
          "HIVE_CLI_ROOT" => hive_cli_root
        }
        ok = Dir.chdir(dir) do
          runner.call(command, env)
        end
        raise Hive::Error, "hive web: bundle install failed in #{dir}" unless ok

        output.puts "hive web: installed Rails bundle in #{dir}" if output
        dir
      ensure
        if lockfile_bytes
          File.binwrite(lockfile, lockfile_bytes)
          FileUtils.chmod(lockfile_mode, lockfile)
        end
      end

      def prepare!(dir: app_dir, runner: nil, output: $stderr)
        default_commands = runner.nil?
        lockfile = File.join(dir, "Gemfile.lock")
        lockfile_bytes = File.binread(lockfile) if File.file?(lockfile)
        lockfile_mode = File.stat(lockfile).mode & 0o777 if lockfile_bytes
        bundle_install!(dir: dir, runner: runner, output: nil)
        runner ||= default_runner(output)
        asset_storage = File.join(dir, "tmp", "assets-build-storage")
        asset_env = {
          "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"),
          "BUNDLE_PATH" => dependency_dir,
          "GEM_HOME" => nil,
          "GEM_PATH" => nil,
          "HIVE_CLI_ROOT" => hive_cli_root,
          "RAILS_ENV" => "production",
          "SECRET_KEY_BASE" => "hive-managed-web-assets-build",
          "HIVE_WEB_STORAGE_DIR" => asset_storage
        }
        command = if default_commands
          rails_argv(dir, "assets:precompile")
        else
          %w[bin/rails assets:precompile]
        end
        ok = Dir.chdir(dir) { runner.call(command, asset_env) }
        raise Hive::Error, "hive web: asset precompile failed in #{dir}" unless ok
        unless assets_ready?(dir)
          raise Hive::Error, "hive web: asset precompile produced no usable CSS/JavaScript in #{dir}"
        end

        output.puts "hive web: installed Rails bundle and compiled assets in #{dir}" if output
        dir
      ensure
        FileUtils.rm_rf(asset_storage) if asset_storage
        if lockfile_bytes
          File.binwrite(lockfile, lockfile_bytes)
          FileUtils.chmod(lockfile_mode, lockfile)
        end
      end

      def default_runner(output)
        lambda do |argv, env|
          destination = output || File::NULL
          system(env, *argv, out: destination, err: destination)
        end
      end

      def bundle_install_argv(dir)
        bundle_argv(dir, "install")
      end

      def rails_argv(dir, *arguments)
        bundle_argv(
          dir, "exec", RbConfig.ruby,
          File.join(dir, "bin", "rails"), *arguments
        )
      end

      def bundle_argv(dir, *arguments)
        version = File.read(File.join(dir, "Gemfile.lock"))[
          /^BUNDLED WITH\s*\n\s+(\S+)\s*$/m, 1
        ].to_s
        unless version.match?(/\A\d+(?:\.\d+){1,3}(?:[.-][0-9A-Za-z]+)*\z/)
          raise Hive::Error,
                "hive web: #{File.join(dir, 'Gemfile.lock')} has no valid BUNDLED WITH version"
        end

        executable = Gem.bin_path("bundler", "bundle", "= #{version}")
        [ RbConfig.ruby, executable, *arguments ]
      rescue Errno::ENOENT
        raise Hive::Error, "hive web: downloaded web bundle does not contain a Gemfile.lock"
      rescue Gem::GemNotFoundException
        raise Hive::Error,
              "hive web: locked Bundler #{version} is unavailable; " \
              "install Bundler #{version} before provisioning Hive web"
      end

      def dependency_dir
        File.join(Hive::Paths.data_home, "web-gems")
      end

      def default_bundle_url
        ENV["HIVE_WEB_BUNDLE_URL"].to_s.empty? ? github_release_url : ENV["HIVE_WEB_BUNDLE_URL"]
      end

      def default_bundle_sha256
        value = ENV["HIVE_WEB_BUNDLE_SHA256"].to_s.strip
        value.empty? ? nil : value
      end

      def github_release_url
        "https://github.com/#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}/releases/download/" \
          "v#{Hive::VERSION}/hive-web-#{Hive::VERSION}.tar.gz"
      end

      def fetch_and_extract(bundle_url, dest, bundle_sha256: default_bundle_sha256,
                            downloader: nil, verifier: nil)
        if File.directory?(bundle_url)
          FileUtils.cp_r(Dir.children(bundle_url).map { |child| File.join(bundle_url, child) }, dest)
          return
        end

        custom_digest = normalize_custom_digest(bundle_sha256) unless default_release_url?(bundle_url)
        downloader ||= method(:download)
        Dir.mktmpdir("hive-web-download") do |download_dir|
          archive_path = File.join(download_dir, File.basename(URI.parse(bundle_url).path))
          downloader.call(bundle_url, archive_path)

          if default_release_url?(bundle_url)
            verify_default_release!(
              bundle_url: bundle_url,
              archive_path: archive_path,
              download_dir: download_dir,
              downloader: downloader,
              verifier: verifier
            )
          else
            verify_digest!(archive_path, custom_digest)
          end

          extract_archive(archive_path, dest)
        end
      rescue URI::InvalidURIError
        raise Hive::Error, "hive web: invalid managed bundle URL #{bundle_url.inspect}"
      end

      def download(url, path)
        # Bound every release-host call: setup must not stall indefinitely on
        # an archive, manifest, signature, or certificate endpoint.
        io = URI.open(url, open_timeout: 30, read_timeout: 120)
        File.open(path, "wb") { |file| IO.copy_stream(io, file) }
      ensure
        io&.close
      end

      def default_release_url?(url)
        url == github_release_url
      end

      def normalize_custom_digest(expected)
        digest = expected.to_s.strip.downcase
        unless digest.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::Error,
                "hive web: custom remote HIVE_WEB_BUNDLE_URL requires a matching " \
                "HIVE_WEB_BUNDLE_SHA256 before download/extraction"
        end

        digest
      end

      def verify_default_release!(bundle_url:, archive_path:, download_dir:, downloader:, verifier: nil)
        release_base = bundle_url.sub(%r{/[^/]+\z}, "")
        manifest = File.join(download_dir, "SHA256SUMS")
        signature = File.join(download_dir, "SHA256SUMS.sig")
        certificate = File.join(download_dir, "SHA256SUMS.pem")
        downloader.call("#{release_base}/SHA256SUMS", manifest)
        downloader.call("#{release_base}/SHA256SUMS.sig", signature)
        downloader.call("#{release_base}/SHA256SUMS.pem", certificate)

        identity = "^https://github\\.com/#{Regexp.escape(Hive::REPO_OWNER)}/" \
                   "#{Regexp.escape(Hive::REPO_NAME)}/\\.github/workflows/" \
                   "release\\.yml@refs/tags/v#{Regexp.escape(Hive::VERSION)}$"
        verify = verifier || method(:verify_manifest_signature)
        ok = verify.call(
          manifest: manifest,
          signature: signature,
          certificate: certificate,
          identity: identity
        )
        raise Hive::Error, "hive web: signed release manifest verification failed" unless ok

        filename = File.basename(archive_path)
        matches = File.readlines(manifest, chomp: true).filter_map do |line|
          match = line.match(/\A([0-9a-fA-F]{64})\s+\*?(?:\.\/)?#{Regexp.escape(filename)}\z/)
          match && match[1].downcase
        end
        unless matches.length == 1
          raise Hive::Error, "hive web: signed SHA256SUMS must contain exactly one digest for #{filename}"
        end

        verify_digest!(archive_path, matches.fetch(0))
      end

      def verify_manifest_signature(manifest:, signature:, certificate:, identity:, runner: nil)
        cosign = Hive::InvokedBinary.which("cosign")
        unless cosign
          raise Hive::Error,
                "hive web: cosign is required to authenticate the managed release bundle; " \
                "install cosign and retry"
        end

        runner ||= method(:capture3_bounded)
        _out, err, status = runner.call(
          cosign, "verify-blob",
          "--certificate", certificate,
          "--signature", signature,
          "--certificate-identity-regexp", identity,
          "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com",
          manifest,
          timeout_sec: COSIGN_TIMEOUT_SEC
        )
        warn "hive web: cosign: #{err.strip}" unless status.success? || err.to_s.strip.empty?
        status.success?
      end

      def capture3_bounded(*argv, timeout_sec:)
        Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stdout_reader = Thread.new { stdout.read }
          stderr_reader = Thread.new { stderr.read }
          unless wait_thread.join(timeout_sec)
            terminate_process_group(wait_thread.pid, wait_thread)
            raise Hive::Error, "hive web: cosign verification timed out after #{timeout_sec}s"
          end

          [ stdout_reader.value, stderr_reader.value, wait_thread.value ]
        ensure
          stdout_reader&.join(1)
          stderr_reader&.join(1)
        end
      end

      def terminate_process_group(pid, wait_thread)
        Process.kill("TERM", -pid)
        return if wait_thread.join(2)

        Process.kill("KILL", -pid)
        wait_thread.join(2)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def verify_digest!(path, expected)
        actual = ::Digest::SHA256.file(path).hexdigest
        return true if actual == expected

        raise Hive::Error,
              "hive web: bundle digest mismatch (expected #{expected}, got #{actual}); refusing extraction"
      end

      def extract_archive(path, dest)
        File.open(path, "rb") do |io|
          Zlib::GzipReader.wrap(io) do |gz|
          Gem::Package::TarReader.new(gz) do |tar|
            tar.each { |entry| extract_entry(entry, dest) }
          end
        end
        end
      end

      def extract_entry(entry, dest)
        relative = entry.full_name.sub(%r{\A\./}, "")
        return if relative.empty?

        target = File.expand_path(relative, dest)
        root = File.expand_path(dest)
        raise Hive::Error, "hive web: unsafe bundle path #{relative.inspect}" unless target.start_with?("#{root}/")

        # Reject symlink/hardlink members outright. The expand_path guard above
        # only validates the member's own path; a symlink pointing outside
        # `dest` followed by a later write THROUGH it could still escape the
        # destination. A Rails app bundle is plain files + dirs, so any link
        # member is unexpected — refuse rather than try to validate the target.
        if entry.symlink? || (entry.respond_to?(:header) && entry.header.typeflag == "1")
          raise Hive::Error, "hive web: refusing link member in bundle #{relative.inspect}"
        end

        if entry.directory?
          FileUtils.mkdir_p(target)
        else
          FileUtils.mkdir_p(File.dirname(target))
          File.open(target, "wb") { |file| IO.copy_stream(entry, file) }
          # Strip setuid/setgid/sticky bits (07000) from the tar member's mode
          # so a crafted bundle member can't land a setuid file; a Rails app
          # bundle only needs ordinary file/dir permission bits.
          FileUtils.chmod(entry.header.mode & 0o0777, target) if entry.header.mode
        end
      end
    end
  end
end
