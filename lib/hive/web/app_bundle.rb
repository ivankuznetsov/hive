require "digest"
require "fileutils"
require "open3"
require "open-uri"
require "rubygems/package"
require "tmpdir"
require "zlib"

require "hive"
require "hive/invoked_binary"
require "hive/paths"

module Hive
  module Web
    module AppBundle
      VERSION_FILE = ".hive-web-version".freeze

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

      def ensure!(bundle_url: default_bundle_url, bundle_sha256: default_bundle_sha256,
                  runner: nil, output: $stderr, downloader: nil, verifier: nil)
        return app_dir if present? && !stale?

        if bundle_url.to_s.empty?
          raise Hive::Error,
                "hive web: managed web app is missing. Set HIVE_WEB_BUNDLE_URL or run from a source checkout."
        end

        tmp = "#{app_dir}.tmp.#{Process.pid}"
        FileUtils.rm_rf(tmp)
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

        # Run `bundle install` against the staged tmp bundle BEFORE swapping it
        # into place. A transient Bundler / native-extension failure then leaves
        # the previous working install untouched instead of replacing it with an
        # unstamped broken bundle. Only after Bundler succeeds do we swap and
        # stamp the version (the stamp is last so a crash between swap and stamp
        # leaves `installed_version` nil → `stale?` true → next `ensure!`
        # re-bootstraps rather than trusting a half-provisioned bundle).
        bundle_install!(dir: tmp, runner: runner, output: output)
        FileUtils.rm_rf(app_dir)
        FileUtils.mkdir_p(File.dirname(app_dir))
        FileUtils.mv(tmp, app_dir)
        File.write(File.join(app_dir, VERSION_FILE), "#{Hive::VERSION}\n")
        app_dir
      ensure
        FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
      end

      def bundle_install!(dir: app_dir, runner: nil, output: $stderr)
        return dir unless File.file?(File.join(dir, "Gemfile"))

        unless File.file?(File.join(hive_cli_root, "hive.gemspec"))
          raise Hive::Error,
                "hive web: installed hive-cli root #{hive_cli_root} has no hive.gemspec; " \
                "reinstall the hive-cli package before provisioning Hive web"
        end

        runner ||= ->(argv, env) { system(env, *argv) }
        env = {
          "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"),
          "HIVE_CLI_ROOT" => hive_cli_root
        }
        %w[GEM_HOME GEM_PATH].each do |name|
          env[name] = ENV[name] unless ENV[name].to_s.empty?
        end
        ok = runner.call(%w[bundle install], env)
        raise Hive::Error, "hive web: bundle install failed in #{dir}" unless ok

        output.puts "hive web: installed Rails bundle in #{dir}" if output
        dir
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
                   "#{Regexp.escape(Hive::REPO_NAME)}/"
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

      def verify_manifest_signature(manifest:, signature:, certificate:, identity:)
        cosign = Hive::InvokedBinary.which("cosign")
        unless cosign
          raise Hive::Error,
                "hive web: cosign is required to authenticate the managed release bundle; " \
                "install cosign and retry"
        end

        _out, err, status = Open3.capture3(
          cosign, "verify-blob",
          "--certificate", certificate,
          "--signature", signature,
          "--certificate-identity-regexp", identity,
          "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com",
          manifest
        )
        warn "hive web: cosign: #{err.strip}" unless status.success? || err.to_s.strip.empty?
        status.success?
      end

      def verify_digest!(path, expected)
        actual = Digest::SHA256.file(path).hexdigest
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
