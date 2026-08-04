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

module HiveReleaseCandidate
  class Artifacts
    MANIFEST_SCHEMA = "hive-release-candidate-artifacts"
    KINDS = %w[gem source skills web].freeze
    LIVE_AGENT_BUILDER_INPUTS = %w[
      packaging/live_agent_skills/proof.rb
      packaging/live_agent_skills/workflow_creator_bundle.rb
      packaging/live_agent_skills/workflow_creator.rb
      packaging/live_agent_skills/workflow_creator_contract.rb
      packaging/live_agent_skills/workflow_creator_execution_contract.rb
      packaging/live_agent_skills/workflow_creator_text_safety.rb
      packaging/live_agent_skills/workflow_creator_values.rb
      packaging/live_agent_skills/build.rb
    ].freeze
    BUILDER_INPUTS = (LIVE_AGENT_BUILDER_INPUTS + [ "packaging/managed_web_archive.rb" ]).freeze
    BUILDER_ARCHIVE_PATHS = BUILDER_INPUTS.each_with_object({}) do |path, result|
      parts = path.split("/")
      (1...parts.length).each do |length|
        ancestor = parts.first(length).join("/")
        result[ancestor.downcase] = [ ancestor, :directory ].freeze
      end
      result[path.downcase] = [ path, :file ].freeze
    end.freeze
    MAX_SOURCE_ARCHIVE_BYTES = 268_435_456
    MAX_SOURCE_ARCHIVE_ENTRIES = 16_384
    MAX_SOURCE_EXPANDED_BYTES = 1_073_741_824
    MAX_BUILDER_INPUT_BYTES = 1_048_576
    MAX_SOURCE_TAR_PADDING_BYTES = 1_048_576
    SOURCE_ENTRY_TYPES = %w[0 5 g].freeze

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
      build_managed_web(export, version, File.join(output, web_name))

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

    def build_managed_web(export, version, destination)
      helper = File.join(export, "packaging", "managed_web_archive.rb")
      unless File.file?(helper) && !File.symlink?(helper)
        raise Error, "committed candidate has no managed web artifact builder"
      end
      script = <<~'RUBY'
        HiveManagedWebArchive.build(
          repo_root: ARGV.fetch(0), candidate_sha: ARGV.fetch(1),
          version: ARGV.fetch(2), destination: ARGV.fetch(3)
        )
      RUBY
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "--disable-gems", "-r", helper, "-e", script,
        repo_root, candidate_sha, version, destination, chdir: export
      )
      unless status.success? && File.file?(destination) && !File.symlink?(destination)
        FileUtils.rm_f(destination)
        raise Error, "committed managed web builder failed: #{stderr.strip}"
      end
    end

    def builder_revision(export)
      digest = Digest::SHA256.new
      BUILDER_INPUTS.each do |label|
        path = File.join(export, label)
        raise Error, "candidate builder input is missing: #{path}" unless File.file?(path) && !File.symlink?(path)
        if File.size(path) > MAX_BUILDER_INPUT_BYTES
          raise Error, "candidate builder input exceeds the size limit: #{label}"
        end
        digest << label << "\0" << File.binread(path) << "\0"
      end
      digest.hexdigest
    end

    def builder_revision_from_candidate(directory, files)
      source_name, = files.find { |_name, record| record["kind"] == "source" }
      raise Error, "candidate source artifact is missing" unless source_name

      source_path = File.join(directory, source_name)
      contents = source_builder_contents(source_path)
      missing = BUILDER_INPUTS - contents.keys
      unless missing.empty?
        raise Error, "candidate source omits builder input #{missing.first}"
      end

      digest = Digest::SHA256.new
      BUILDER_INPUTS.each do |name|
        digest << name << "\0" << contents.fetch(name) << "\0"
      end
      digest.hexdigest
    rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError => e
      raise Error, "cannot verify candidate source builder inputs: #{e.message}"
    end

    def source_builder_contents(source_path)
      unless File.size(source_path).between?(1, MAX_SOURCE_ARCHIVE_BYTES)
        raise Error, "candidate source archive exceeds the compressed-size limit"
      end
      state = { contents: {}, destinations: {}, entries: 0, expanded: 0, global_header: false }
      compressed = File.open(source_path, "rb")
      gzip = Zlib::GzipReader.new(compressed)
      Gem::Package::TarReader.new(gzip) do |tar|
        tar.each { |entry| collect_source_entry!(entry, state) }
      end
      validate_source_tail!(gzip, compressed, state)
      gzip = nil
      state.fetch(:contents)
    ensure
      gzip&.close
      compressed&.close unless compressed&.closed?
    end

    def collect_source_entry!(entry, state)
      state[:entries] += 1
      state[:expanded] += entry.size
      unless state[:entries] <= MAX_SOURCE_ARCHIVE_ENTRIES && state[:expanded] <= MAX_SOURCE_EXPANDED_BYTES
        raise Error, "candidate source archive exceeds the entry or expanded-size limit"
      end
      type = entry.header.typeflag
      raise Error, "candidate source contains an unsupported archive entry" unless SOURCE_ENTRY_TYPES.include?(type)
      return collect_global_header!(entry, state) if type == "g"

      name = source_entry_name!(entry)
      return unless name
      key = name.downcase
      raise Error, "candidate source duplicates an archive destination" if state[:destinations].key?(key)
      state[:destinations][key] = true
      collect_builder_entry!(entry, state, name, key)
    end

    def source_entry_name!(entry)
      raw = entry.full_name.sub(%r{\A\./}, "")
      name = entry.directory? ? raw.delete_suffix("/") : raw
      return if name == "." && entry.directory?
      parts = name.split("/", -1)
      unsafe = name.start_with?("/") || parts.any? { |part| part.empty? || part == "." || part == ".." }
      raise Error, "candidate source contains an unsafe archive entry" if unsafe
      name
    end

    def collect_builder_entry!(entry, state, name, key)
      expected, expected_type = BUILDER_ARCHIVE_PATHS[key]
      return unless expected
      valid_type = expected_type == :directory ? entry.directory? : entry.file?
      unless name == expected && valid_type
        raise Error, "candidate source builder path has a noncanonical name or wrong type"
      end
      return unless expected_type == :file
      raise Error, "candidate source builder input exceeds the size limit" if entry.size > MAX_BUILDER_INPUT_BYTES
      state[:contents][expected] = entry.read(MAX_BUILDER_INPUT_BYTES + 1)
    end

    def collect_global_header!(entry, state)
      expected = "52 comment=#{candidate_sha}\n"
      valid = !state[:global_header] && entry.full_name == "pax_global_header" &&
        entry.size == expected.bytesize && entry.read(expected.bytesize + 1) == expected
      raise Error, "candidate source contains noncanonical global archive metadata" unless valid
      state[:global_header] = true
    end

    def validate_source_tail!(gzip, compressed, state)
      padding = 0
      begin
        loop do
          chunk = gzip.readpartial(16_384)
          padding += chunk.bytesize
          state[:expanded] += chunk.bytesize
          valid = padding <= MAX_SOURCE_TAR_PADDING_BYTES && state[:expanded] <= MAX_SOURCE_EXPANDED_BYTES &&
            chunk.each_byte.all?(&:zero?)
          raise Error, "candidate source contains noncanonical tar padding" unless valid
        end
      rescue EOFError
        nil
      end
      unused = gzip.unused
      gzip.finish
      trailing_member = (unused && !unused.empty?) || compressed.read(1)
      raise Error, "candidate source must contain exactly one gzip member" if trailing_member
      unless padding.between?(512, MAX_SOURCE_TAR_PADDING_BYTES) && (padding % 512).zero?
        raise Error, "candidate source contains noncanonical tar padding"
      end
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
