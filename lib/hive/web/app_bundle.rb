require "fileutils"
require "open-uri"
require "rubygems/package"
require "zlib"

require "hive"
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

      def ensure!(bundle_url: default_bundle_url, runner: nil, output: $stderr)
        return app_dir if present? && !stale?

        if bundle_url.to_s.empty?
          raise Hive::Error,
                "hive web: managed web app is missing. Set HIVE_WEB_BUNDLE_URL or run from a source checkout."
        end

        tmp = "#{app_dir}.tmp.#{Process.pid}"
        FileUtils.rm_rf(tmp)
        FileUtils.mkdir_p(tmp)
        fetch_and_extract(bundle_url, tmp)
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

        runner ||= ->(argv, env) { system(env, *argv) }
        ok = runner.call(%w[bundle install],
                         { "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"),
                           "HIVE_CLI_ROOT" => hive_cli_root })
        raise Hive::Error, "hive web: bundle install failed in #{dir}" unless ok

        output.puts "hive web: installed Rails bundle in #{dir}" if output
        dir
      end

      def default_bundle_url
        ENV["HIVE_WEB_BUNDLE_URL"].to_s.empty? ? github_release_url : ENV["HIVE_WEB_BUNDLE_URL"]
      end

      def github_release_url
        "https://github.com/#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}/releases/download/" \
          "v#{Hive::VERSION}/hive-web-#{Hive::VERSION}.tar.gz"
      end

      def fetch_and_extract(bundle_url, dest)
        if File.directory?(bundle_url)
          FileUtils.cp_r(Dir.children(bundle_url).map { |child| File.join(bundle_url, child) }, dest)
          return
        end

        # Bound the one network call in the bootstrap path: a slow/wedged
        # release host must not stall `hive setup` / `hive web install`
        # indefinitely, matching the timeout discipline used elsewhere.
        io = URI.open(bundle_url, open_timeout: 30, read_timeout: 120)
        Zlib::GzipReader.wrap(io) do |gz|
          Gem::Package::TarReader.new(gz) do |tar|
            tar.each { |entry| extract_entry(entry, dest) }
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
