# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "open-uri"
require "securerandom"
require_relative "asset_verifier"
require_relative "baseline_catalog"

module HiveReleaseCandidate
  # Explicitly materializes the reviewed, digest-pinned baseline dependency
  # closures. Candidate execution never calls this class: operators and the
  # hosted staging phase invoke it before the no-network sandbox begins.
  class BaselineCacheMaterializer
    RUBYGEMS_DOWNLOAD_ROOT = "https://rubygems.org/downloads"

    def initialize(repo_root:, cache_root:, candidate_sha:, downloader: nil,
                   package_authenticator: nil)
      @repo_root = File.expand_path(repo_root)
      @cache_root = safe_cache_root(cache_root)
      @candidate_sha = candidate_sha.to_s
      raise UsageError, "candidate SHA must be exact" unless SAFE_SHA.match?(@candidate_sha)

      catalog_content = git_show(@candidate_sha, "packaging/release_candidate/baselines.yml")
      @catalog = BaselineCatalog.parse(
        catalog_content,
        source: "#{@candidate_sha}:packaging/release_candidate/baselines.yml"
      )
      @downloader = downloader || method(:download)
      @package_authenticator = package_authenticator || method(:authenticate_packages)
    end

    def call
      entries = @catalog.entries
      packages = @package_authenticator.call(entries)
      rows = entries.map { |entry| materialize(entry) }
      attestation = write_attestation(packages, rows)
      {
        "status" => "materialized",
        "candidate_sha" => @candidate_sha,
        "cache_root" => @cache_root,
        "rows" => rows,
        "attestation" => attestation
      }
    end

    private

    def materialize(entry)
      closure_root = File.join(@cache_root, "closures", entry.id)
      gems_root = File.join(closure_root, "gems")
      owned_directory!(closure_root)
      owned_directory!(gems_root)

      lock_contents = {
        "producer" => git_show(
          entry.dependency_closure.fetch("lock").fetch("source_tag"), "Gemfile.lock"
        )
      }
      if entry.dependency_closure["observer_lock"]
        lock_contents["observer"] = git_show(
          entry.dependency_closure.fetch("observer_lock").fetch("source_tag"), "Gemfile.lock"
        )
      end
      offline = entry.dependency_closure.fetch("offline_cache")
      manifest_content = git_show(@candidate_sha, offline.fetch("manifest_path"))
      unless Digest::SHA256.hexdigest(manifest_content) == offline.fetch("manifest_sha256")
        raise Error, "#{entry.id} reviewed offline cache manifest digest mismatch"
      end
      @catalog.verify_dependency_closure!(
        entry,
        lock_contents: lock_contents,
        cache_manifest_content: manifest_content
      )

      write_exact(File.join(closure_root, "producer.Gemfile.lock"), lock_contents.fetch("producer"))
      if lock_contents["observer"]
        write_exact(
          File.join(closure_root, "observer.Gemfile.lock"), lock_contents.fetch("observer")
        )
      end
      write_exact(File.join(closure_root, offline.fetch("manifest_filename")), manifest_content)

      artifacts = JSON.parse(manifest_content).fetch("artifacts")
      artifacts.each { |artifact| fetch_exact(artifact, gems_root) }
      @catalog.verify_dependency_closure!(
        entry,
        lock_contents: lock_contents,
        cache_manifest_content: manifest_content,
        artifact_root: gems_root
      )
      {
        "row_id" => entry.id,
        "manifest_sha256" => offline.fetch("manifest_sha256"),
        "artifact_count" => artifacts.length,
        "sha256" => Digest::SHA256.hexdigest(
          lock_contents.keys.sort.map do |role|
            Digest::SHA256.hexdigest(lock_contents.fetch(role))
          end.join + offline.fetch("manifest_sha256")
        )
      }
    end

    def authenticate_packages(entries)
      entries.flat_map do |entry|
        entry.packages.map do |role, package|
          verifier = AssetVerifier.new(
            cache_root: File.join(@cache_root, package.fetch("tag"))
          )
          verifier.verify_authenticated_package!(
            package,
            signature_verifier: method(:verify_signature)
          )
          descriptors = [
            package.fetch("artifact"),
            *%w[checksum signature certificate].map do |kind|
              package.fetch("authentication").fetch(kind)
            end
          ]
          verifier.verify_set!(descriptors).map do |verified|
            verified.merge(
              "row_id" => entry.id,
              "role" => role,
              "tag" => package.fetch("tag")
            )
          end
        end.flatten
      end
    end

    def verify_signature(checksum:, signature:, certificate:, issuer:, identity:)
      _stdout, stderr, status = Open3.capture3(
        "cosign", "verify-blob",
        "--certificate", certificate,
        "--signature", signature,
        "--certificate-oidc-issuer", issuer,
        "--certificate-identity", identity,
        checksum
      )
      raise Error, "cosign authentication failed: #{stderr.strip}" unless status.success?

      true
    rescue Errno::ENOENT
      raise UnavailableError, "cosign is required to authenticate cached baseline assets"
    end

    def write_attestation(packages, rows)
      release_assets_sha256 = Digest::SHA256.hexdigest(JSON.generate(
        packages.map do |item|
          [
            item.fetch("tag"), item.fetch("filename"),
            item.fetch("sha256"), item.fetch("size")
          ]
        end.sort
      ))
      closure_sha256 = Digest::SHA256.hexdigest(JSON.generate(
        rows.sort_by { |row| row.fetch("row_id") }.map { |row| row.fetch("sha256") }
      ))
      document = {
        "schema" => "hive-release-candidate-baseline-cache-attestation",
        "schema_version" => 1,
        "baseline_catalog_sha256" => @catalog.digest,
        "release_assets_sha256" => release_assets_sha256,
        "verified_dependency_closure_sha256" => closure_sha256,
        "rows" => rows.map { |row| row.fetch("row_id") }.sort
      }
      path = File.join(
        @cache_root, "attestations", "#{@catalog.digest}.json"
      )
      owned_directory!(File.dirname(path))
      content = JSON.generate(document) + "\n"
      write_exact(path, content)
      {
        "path" => path,
        "sha256" => Digest::SHA256.hexdigest(content),
        "release_assets_sha256" => release_assets_sha256,
        "verified_dependency_closure_sha256" => closure_sha256
      }
    end

    def fetch_exact(artifact, root)
      filename = artifact.fetch("filename")
      path = File.join(root, filename)
      return path if exact_file?(path, artifact)
      raise Error, "refusing to replace invalid cached gem #{filename}" if File.exist?(path) || File.symlink?(path)

      temporary = File.join(root, ".#{filename}.#{Process.pid}.#{SecureRandom.hex(6)}.part")
      @downloader.call("#{RUBYGEMS_DOWNLOAD_ROOT}/#{filename}", temporary)
      unless exact_file?(temporary, artifact)
        raise Error, "downloaded gem digest mismatch for #{filename}"
      end
      File.rename(temporary, path)
      path
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def download(url, output)
      URI.open(url, "rb") do |input|
        File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          IO.copy_stream(input, file)
        end
      end
    rescue OpenURI::HTTPError, SystemCallError => e
      raise UnavailableError, "cannot fetch reviewed baseline gem #{File.basename(output)}: #{e.message}"
    end

    def exact_file?(path, artifact)
      stat = File.lstat(path)
      stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid &&
        stat.size == artifact.fetch("size") &&
        Digest::SHA256.file(path).hexdigest == artifact.fetch("sha256")
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def write_exact(path, content)
      if File.exist?(path) || File.symlink?(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
               stat.uid == Process.uid && File.binread(path) == content
          raise Error, "refusing to replace invalid baseline cache input #{File.basename(path)}"
        end
        return
      end

      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(6)}.part"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def safe_cache_root(path)
      root = File.expand_path(path)
      allowed = File.join(@repo_root, "tmp") + File::SEPARATOR
      unless root.start_with?(allowed) && root != allowed.chomp(File::SEPARATOR)
        raise Error, "baseline cache root must stay beneath repository tmp"
      end
      owned_directory!(root)
      root
    end

    def owned_directory!(path)
      FileUtils.mkdir_p(path, mode: 0o700)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error, "baseline cache path must be an owned directory"
      end
      path
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "cannot create baseline cache path: #{e.message}"
    end

    def git_show(ref, path)
      stdout, stderr, status = Open3.capture3(
        "git", "show", "#{ref}:#{path}", chdir: @repo_root
      )
      raise Error, "cannot read reviewed #{ref}:#{path}: #{stderr.strip}" unless status.success?

      stdout
    end
  end
end
