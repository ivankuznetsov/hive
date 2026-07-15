require "fileutils"
require "open3"
require "hive/atomic_file"
require "hive/paths"
require "hive/honeycomb/catalog"

module Hive
  module Honeycomb
    class Registry
      CATALOG_REF = "refs/hive/catalog".freeze

      attr_reader :remote_url, :cache_dir, :repository_path, :catalog_path

      def initialize(
        remote_url: REMOTE_URL,
        cache_dir: Hive::Paths.honeycomb_cache_dir,
        runner: nil
      )
        @remote_url = remote_url
        @cache_dir = File.expand_path(cache_dir)
        @repository_path = File.join(@cache_dir, "registry.git")
        @catalog_path = File.join(@cache_dir, "catalog.yml")
        @runner = runner
      end

      def refresh!
        prepare_repository!
        fetch_catalog!
        raw = git!("show", "#{CATALOG_REF}:catalog.yml")
        parsed = Catalog.load(raw)
        Hive::AtomicFile.write(catalog_path, raw, mode: 0o644)
        parsed
      rescue CatalogError
        raise
      rescue RegistryError
        raise
      rescue StandardError => e
        raise RegistryError, "honeycomb registry refresh failed: #{e.message}"
      end

      def catalog
        raise RegistryError, "honeycomb catalog cache is unavailable; run a remote operation first" unless File.file?(catalog_path)
        Catalog.load(File.binread(catalog_path))
      rescue SystemCallError, IOError => e
        raise RegistryError, "honeycomb catalog cache is unreadable: #{e.message}"
      end

      def resolve(raw_reference, refresh: true)
        selected_catalog = refresh ? refresh! : catalog
        pin = selected_catalog.resolve(raw_reference, allow_unknown_full_sha: true)
        commit = peel_commit!(pin.sha, "object #{pin.sha}")
        if pin.tag
          tagged = peel_commit!("refs/tags/#{pin.tag}", "tag #{pin.tag.inspect}")
          unless tagged == commit
            raise ResolutionError,
                  "catalog tag #{pin.tag.inspect} resolves to #{tagged}, not recorded commit #{commit}"
          end
        end
        pin.with(sha: commit)
      end

      # Raw object access used by Package. The caller supplies an immutable
      # commit and object/path syntax is assembled internally, never from a
      # mutable branch name.
      def git_object!(*args)
        git!(*args)
      end

      private

      def prepare_repository!
        FileUtils.mkdir_p(cache_dir)
        unless File.directory?(repository_path)
          run!("git", "init", "--bare", repository_path)
          run!("git", "--git-dir", repository_path, "remote", "add", "origin", remote_url)
        end
        run!("git", "--git-dir", repository_path, "remote", "set-url", "origin", remote_url)
      end

      def fetch_catalog!
        errors = []
        %w[main master].each do |branch|
          _out, err, status = capture(
            "git", "--git-dir", repository_path, "fetch", "--force", "--prune", "--tags", "origin",
            "+refs/heads/#{branch}:#{CATALOG_REF}"
          )
          return if status_success?(status)
          errors << err.to_s.strip
        end
        raise RegistryError, "could not fetch the public honeycomb catalog: #{errors.reject(&:empty?).join(' / ')}"
      end

      def peel_commit!(revision, label)
        value = git!("rev-parse", "--verify", "--end-of-options", "#{revision}^{commit}").strip.downcase
        unless Catalog::SHA_RE.match?(value)
          raise ResolutionError, "#{label} did not resolve to a full commit id"
        end
        value
      rescue RegistryError => e
        raise ResolutionError, "#{label} is not an available commit: #{e.message}"
      end

      def git!(*args)
        run!("git", "--git-dir", repository_path, *args)
      end

      def run!(*argv)
        out, err, status = capture(*argv)
        return out if status_success?(status)
        raise RegistryError, "#{argv.join(' ')} failed: #{err.to_s.strip.empty? ? out : err}"
      end

      def capture(*argv)
        result = @runner ? @runner.call(*argv) : Open3.capture3(*argv)
        return result if result.is_a?(Array) && result.length == 3
        [ result.stdout, result.stderr, result.status ]
      rescue SystemCallError, IOError => e
        raise RegistryError, "could not run #{argv.first}: #{e.message}"
      end

      def status_success?(status)
        status.respond_to?(:success?) ? status.success? : status.to_i.zero?
      end
    end
  end
end
