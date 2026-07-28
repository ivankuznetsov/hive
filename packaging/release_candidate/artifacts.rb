# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"
require "zlib"
require_relative "paths"
require_relative "../managed_web_archive"

module HiveReleaseCandidate
  class Artifacts
    MANIFEST_SCHEMA = "hive-release-candidate-artifacts"
    KINDS = %w[gem source skills web].freeze
    LIVE_AGENT_BUILDER_INPUTS = %w[
      packaging/live_agent_skills/proof.rb
      packaging/live_agent_skills/build.rb
      packaging/live_agent_skills/workflow_creator_contract.rb
      packaging/live_agent_skills/openclaw_creator_proof/containment_root.rb
      packaging/live_agent_skills/openclaw_creator_proof/installation_identity.rb
      packaging/live_agent_skills/openclaw_creator_proof/gateway_runtime/bounded_regular_reader.rb
    ].freeze

    attr_reader :repo_root, :candidate_sha, :candidate_dir

    def initialize(repo_root:, candidate_sha:, candidate_dir:)
      @repo_root = File.expand_path(repo_root)
      @candidate_sha = candidate_sha.to_s.downcase
      unless SAFE_SHA.match?(@candidate_sha)
        raise Error, "candidate_sha must be a full 40-character commit SHA"
      end
      @candidate_dir = File.expand_path(candidate_dir)
    end

    def call
      return verify! if File.directory?(candidate_dir) && !File.symlink?(candidate_dir)
      if File.exist?(candidate_dir) || File.symlink?(candidate_dir)
        raise Error, "candidate artifact path collision: #{candidate_dir}"
      end

      parent = File.dirname(candidate_dir)
      FileUtils.mkdir_p(parent, mode: 0o700)
      staging = Dir.mktmpdir(".candidate-build-", parent)
      output = File.join(staging, "candidate")
      FileUtils.mkdir_p(output, mode: 0o700)

      begin
        build_into(output, staging)
        manifest = verify_directory!(output)
        File.rename(output, candidate_dir)
        immutable_tree!(candidate_dir)
        manifest
      ensure
        FileUtils.rm_rf(staging)
      end
    end

    def verify!
      verify_directory!(candidate_dir)
    end

    private

    def build_into(output, staging)
      version = committed_version
      source_name = "hive-source-#{candidate_sha}.tar.gz"
      source_archive = File.join(staging, source_name)
      git_archive(candidate_sha, source_archive)

      export = File.join(staging, "source")
      FileUtils.mkdir_p(export, mode: 0o700)
      extract_archive(source_archive, export)

      gem_name = "hive-cli-#{version}.gem"
      gem_path = File.join(staging, gem_name)
      build_gem(export, gem_path)

      incumbent = File.join(export, "packaging", "live_agent_skills", "build.rb")
      unless File.file?(incumbent) && !File.symlink?(incumbent)
        raise Error, "committed candidate has no incumbent artifact builder"
      end
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, incumbent, candidate_sha, gem_path, source_archive, output,
        chdir: export
      )
      raise Error, "incumbent candidate builder failed: #{stderr.strip}" unless status.success?

      incumbent_manifest_path = File.join(output, "artifact-manifest.json")
      incumbent_manifest = JSON.parse(File.read(incumbent_manifest_path))
      FileUtils.rm_f(incumbent_manifest_path)

      web_name = "hive-web-#{version}.tar.gz"
      HiveManagedWebArchive.build(
        repo_root: repo_root, candidate_sha: candidate_sha, version: version,
        destination: File.join(output, web_name)
      )

      expected = {
        "gem" => gem_name,
        "source" => source_name,
        "skills" => "hive-agent-skills-#{candidate_sha}.tar.gz",
        "web" => web_name
      }
      files = expected.to_h do |kind, name|
        path = File.join(output, name)
        raise Error, "candidate builder omitted #{kind} artifact #{name}" unless File.file?(path) && !File.symlink?(path)
        [
          name,
          {
            "kind" => kind,
            "sha256" => Digest::SHA256.file(path).hexdigest,
            "size" => File.size(path)
          }
        ]
      end
      manifest = {
        "schema" => MANIFEST_SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "candidate_sha" => candidate_sha,
        "hive_version" => version,
        "skill_version" => incumbent_manifest.fetch("skill_version"),
        "canonical_digest" => incumbent_manifest.fetch("canonical_digest"),
        "builder_revision" => builder_revision(export),
        "files" => files
      }
      write_private_json(File.join(output, "manifest.json"), manifest)
    rescue JSON::ParserError, KeyError => e
      raise Error, "invalid incumbent candidate manifest: #{e.message}"
    rescue HiveManagedWebArchive::Error => e
      raise Error, e.message
    end

    def verify_directory!(directory)
      unless File.directory?(directory) && !File.symlink?(directory)
        raise Error, "candidate directory is not a regular directory: #{directory}"
      end
      manifest_path = File.join(directory, "manifest.json")
      unless File.file?(manifest_path) && !File.symlink?(manifest_path)
        raise Error, "candidate manifest is missing or unsafe"
      end
      manifest_stat = File.lstat(manifest_path)
      unless manifest_stat.file? && manifest_stat.nlink == 1 && manifest_stat.uid == Process.uid
        raise Error, "candidate manifest is not a private regular file"
      end
      manifest = JSON.parse(File.read(manifest_path))
      required = %w[
        builder_revision candidate_sha canonical_digest files hive_version
        schema schema_version skill_version
      ]
      unless manifest.is_a?(Hash) && manifest.keys.sort == required.sort &&
             manifest["schema"] == MANIFEST_SCHEMA &&
             manifest["schema_version"] == SCHEMA_VERSION &&
             manifest["candidate_sha"] == candidate_sha
        raise Error, "candidate artifact manifest identity is invalid"
      end
      unless /\A[0-9a-f]{64}\z/.match?(manifest["builder_revision"].to_s)
        raise Error, "candidate builder revision is invalid"
      end
      unless /\A[0-9a-f]{64}\z/.match?(manifest["canonical_digest"].to_s)
        raise Error, "candidate canonical digest is invalid"
      end
      if manifest["hive_version"].to_s.empty? || manifest["skill_version"].to_s.empty?
        raise Error, "candidate version identity is invalid"
      end
      files = manifest["files"]
      unless files.is_a?(Hash) && files.size == KINDS.size &&
             files.values.map { |record| record["kind"] }.sort == KINDS.sort
        raise Error, "candidate artifact manifest must contain the exact artifact kinds"
      end
      expected_names = files.keys + [ "manifest.json" ]
      unless Dir.children(directory).sort == expected_names.sort
        raise Error, "candidate directory contains unmanifested artifacts"
      end
      files.each do |name, record|
        validate_name!(name)
        unless record.is_a?(Hash) && record.keys.sort == %w[kind sha256 size] &&
               KINDS.include?(record["kind"]) &&
               /\A[0-9a-f]{64}\z/.match?(record["sha256"]) &&
               record["size"].is_a?(Integer) && record["size"] >= 0
          raise Error, "invalid artifact record for #{name}"
        end
        path = File.join(directory, name)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
          raise Error, "candidate artifact is not a private regular file: #{name}"
        end
        raise Error, "artifact size mismatch for #{name}" unless stat.size == record["size"]
        unless Digest::SHA256.file(path).hexdigest == record["sha256"]
          raise Error, "artifact digest mismatch for #{name}"
        end
      end
      expected_builder = builder_revision_from_candidate(directory, files)
      unless manifest["builder_revision"] == expected_builder
        raise Error, "candidate builder revision does not match the immutable build inputs"
      end
      manifest
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise Error, "cannot verify candidate artifacts: #{e.message}"
    end

    def validate_name!(name)
      unless name.is_a?(String) && File.basename(name) == name && name != "." && name != ".."
        raise Error, "unsafe artifact path #{name.inspect}"
      end
    end

    def committed_version
      source = git_show("lib/hive/version.rb")
      match = source.match(/\bVERSION\s*=\s*["']([^"']+)["']/)
      raise Error, "cannot read committed Hive version" unless match

      match[1]
    end

    def git_show(path)
      stdout, stderr, status = Open3.capture3("git", "show", "#{candidate_sha}:#{path}", chdir: repo_root)
      raise Error, "cannot read committed #{path}: #{stderr.strip}" unless status.success?

      stdout
    end

    def git_archive(treeish, destination)
      _stdout, stderr, status = Open3.capture3(
        "git", "archive", "--format=tar.gz", "--output", destination, treeish,
        chdir: repo_root
      )
      raise Error, "cannot export committed candidate: #{stderr.strip}" unless status.success?
    end

    def extract_archive(archive, destination)
      _stdout, stderr, status = Open3.capture3("tar", "-xzf", archive, "-C", destination)
      raise Error, "cannot extract committed candidate: #{stderr.strip}" unless status.success?
    end

    def build_gem(export, destination)
      _stdout, stderr, status = Open3.capture3(
        "gem", "build", "hive.gemspec", "--output", destination, chdir: export
      )
      raise Error, "cannot build committed candidate gem: #{stderr.strip}" unless status.success?
    end

    def builder_revision(export)
      paths = LIVE_AGENT_BUILDER_INPUTS.map { |relative| File.join(export, relative) }
      paths << File.expand_path("../managed_web_archive.rb", __dir__)
      digest = Digest::SHA256.new
      paths.each do |path|
        raise Error, "candidate builder input is missing: #{path}" unless File.file?(path) && !File.symlink?(path)
        digest << File.basename(path) << "\0" << File.binread(path) << "\0"
      end
      digest.hexdigest
    end

    def builder_revision_from_candidate(directory, files)
      source_name, = files.find { |_name, record| record["kind"] == "source" }
      raise Error, "candidate source artifact is missing" unless source_name

      wanted = LIVE_AGENT_BUILDER_INPUTS
      contents = {}
      Zlib::GzipReader.open(File.join(directory, source_name)) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            name = entry.full_name.sub(%r{\A\./}, "")
            contents[name] = entry.read if entry.file? && wanted.include?(name)
          end
        end
      end
      missing = wanted - contents.keys
      unless missing.empty?
        raise Error, "candidate source omits builder input #{missing.first}"
      end

      digest = Digest::SHA256.new
      wanted.each do |name|
        digest << File.basename(name) << "\0" << contents.fetch(name) << "\0"
      end
      managed = File.expand_path("../managed_web_archive.rb", __dir__)
      unless File.file?(managed) && !File.symlink?(managed)
        raise Error, "managed web builder input is missing"
      end
      digest << File.basename(managed) << "\0" << File.binread(managed) << "\0"
      digest.hexdigest
    rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError => e
      raise Error, "cannot verify candidate source builder inputs: #{e.message}"
    end

    def write_private_json(path, value)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(value))
        file.write("\n")
        file.flush
        file.fsync
      end
    end

    def immutable_tree!(path)
      Dir.children(path).each { |name| File.chmod(0o400, File.join(path, name)) }
      File.chmod(0o500, path)
    end
  end
end
