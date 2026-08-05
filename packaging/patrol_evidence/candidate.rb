# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "rubygems/package"
require "yaml"

module HivePatrolEvidence
  # Admits one exact candidate archive and its post-install identity closure.
  class Candidate
    class Error < StandardError
      attr_reader :reason

      def initialize(reason, message = reason)
        @reason = reason
        super(message)
      end
    end

    MODULES = %w[architecture-patrol patrol].freeze
    MAX_MEMBERS = 4_096
    MAX_TOTAL_BYTES = 256 * 1024 * 1024
    MAX_MEMBER_BYTES = 256 * 1024 * 1024
    MAX_PATH_BYTES = 240
    MAX_PATH_DEPTH = 32
    MAX_MANIFEST_BYTES = 1024 * 1024
    MAX_CLOSURE_MEMBERS = 4_096
    CHUNK_BYTES = 64 * 1024
    SHA = /\A[0-9a-f]{40}\z/
    DIGEST = /\A[0-9a-f]{64}\z/
    IDENTITY_KEYS = %w[
      dependency_closure dependency_closure_sha256 gem_sha256 installed_hive_sha256
      module_manifest_sha256 toolchain toolchain_sha256
    ].freeze
    CLOSURE_KEYS = %w[full_name name platform spec_sha256 version].freeze
    TOOLCHAIN_KEYS = %w[bundler ruby rubygems].freeze

    def initialize(repo_root:, controller_sha:, candidate_sha:, command_runner: nil)
      @repo_root = File.expand_path(repo_root)
      @controller_sha = controller_sha.to_s.downcase
      @candidate_sha = candidate_sha.to_s.downcase
      @command_runner = command_runner || method(:run_command)
      validate_input!
    end

    def prepare!(run_root:)
      root = owned_directory!(run_root, "candidate run root")
      archive = File.join(root, "candidate.tar")
      raise Error.new("path_custody", "candidate archive destination already exists") if
        File.exist?(archive) || File.symlink?(archive)

      @command_runner.call(
        [ "git", "-C", @repo_root, "archive", "--format=tar", "--output", archive, @candidate_sha ],
        "archive candidate"
      )
      stat = File.lstat(archive)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid &&
             (stat.mode & 0o022).zero? && stat.size.between?(1, MAX_TOTAL_BYTES)
        raise Error.new("candidate_archive", "candidate archive file is unsafe")
      end
      @archive_identity = stat
      inventory = self.class.send(:inspect_archive!, archive)
      manifests = load_module_manifests
      @prepared = {
        "controller_sha" => @controller_sha,
        "candidate_sha" => @candidate_sha,
        "archive_path" => archive,
        "archive_sha256" => inventory.fetch("archive_sha256"),
        "archive_member_count" => inventory.fetch("archive_member_count"),
        "archive_total_bytes" => inventory.fetch("archive_total_bytes"),
        "module_manifests" => manifests,
        "module_manifest_sha256" => digest_json(manifests)
      }.freeze
    rescue Error
      raise
    rescue SystemCallError, KeyError, TypeError
      raise Error.new("candidate_archive", "candidate archive admission failed"), cause: nil
    end

    def verify!(receipt:)
      raise Error.new("candidate_identity", "candidate was not prepared") unless @prepared
      verify_archive!
      row = receipt.fetch("candidate")
      unless row.is_a?(Hash) && row.keys.sort == %w[archive_sha256 candidate_sha identity_after identity_before] &&
             row.values_at("candidate_sha", "archive_sha256") ==
               @prepared.values_at("candidate_sha", "archive_sha256")
        raise Error.new("candidate_identity", "sandbox candidate binding differs")
      end
      before = admit_identity(row.fetch("identity_before"))
      after = admit_identity(row.fetch("identity_after"))
      raise Error.new("candidate_identity", "installed candidate identity drifted") unless before == after
      unless before.fetch("module_manifest_sha256") == @prepared.fetch("module_manifest_sha256")
        raise Error.new("candidate_identity", "installed module manifests differ")
      end

      {
        "candidate_sha" => @candidate_sha,
        "archive_sha256" => @prepared.fetch("archive_sha256"),
        "archive_member_count" => @prepared.fetch("archive_member_count"),
        "archive_total_bytes" => @prepared.fetch("archive_total_bytes"),
        "module_manifest_sha256" => @prepared.fetch("module_manifest_sha256"),
        "gem_sha256" => before.fetch("gem_sha256"),
        "installed_hive_sha256" => before.fetch("installed_hive_sha256"),
        "dependency_closure_sha256" => before.fetch("dependency_closure_sha256"),
        "toolchain_sha256" => before.fetch("toolchain_sha256")
      }.freeze
    rescue Error
      raise
    rescue KeyError, TypeError
      raise Error.new("candidate_identity", "sandbox candidate identity is malformed"), cause: nil
    end

    class << self
      private

      def inspect_archive!(path)
        digest = Digest::SHA256.new
        File.open(path, read_flags) do |file|
          while (chunk = file.read(CHUNK_BYTES))
            digest.update(chunk)
          end
        end

        count = 0
        total = 0
        paths = {}
        File.open(path, read_flags) do |file|
          Gem::Package::TarReader.new(file) do |tar|
            tar.each do |entry|
              count += 1
              raise Error.new("candidate_archive", "candidate archive has too many members") if
                count > MAX_MEMBERS
              kind = entry_kind(entry)
              if kind == :metadata
                size = entry.header.size
                unless size.is_a?(Integer) && size.between?(0, MAX_MEMBER_BYTES)
                  raise Error.new("candidate_archive", "candidate archive metadata is oversized")
                end
                total += size
                raise Error.new("candidate_archive", "candidate archive is oversized") if total > MAX_TOTAL_BYTES
                consume(entry)
                next
              end
              name = safe_path(entry.full_name, directory: kind == :directory)
              raise Error.new("candidate_archive", "candidate archive has duplicate members") if paths.key?(name)
              size = entry.header.size
              unless size.is_a?(Integer) && size.between?(0, MAX_MEMBER_BYTES)
                raise Error.new("candidate_archive", "candidate archive member is oversized")
              end
              total += size
              raise Error.new("candidate_archive", "candidate archive is oversized") if total > MAX_TOTAL_BYTES
              reject_file_parent!(paths, name)
              paths[name] = kind
              consume(entry) if kind == :file
            end
          end
        end
        raise Error.new("candidate_archive", "candidate archive is empty") if paths.empty?
        {
          "archive_sha256" => digest.hexdigest,
          "archive_member_count" => count,
          "archive_total_bytes" => total
        }
      rescue Error
        raise
      rescue SystemCallError, Gem::Package::TarInvalidError, ArgumentError
        raise Error.new("candidate_archive", "candidate archive is malformed"), cause: nil
      end

      def entry_kind(entry)
        case entry.header.typeflag
        when "0", "\0" then :file
        when "5" then :directory
        when "g" then :metadata
        else raise Error.new("candidate_archive", "candidate archive contains a special member")
        end
      end

      def safe_path(raw, directory:)
        name = raw.to_s.dup.force_encoding(Encoding::UTF_8)
        name = name.delete_suffix("/") if directory
        clean = Pathname.new(name).cleanpath.to_s
        safe = name.valid_encoding? && !name.empty? && name.bytesize <= MAX_PATH_BYTES &&
          name == clean && !Pathname.new(name).absolute? && !name.start_with?("../") &&
          name.split("/").none? { |part| part.empty? || part == "." || part == ".." } &&
          name.count("/") + 1 <= MAX_PATH_DEPTH
        raise Error.new("candidate_archive", "candidate archive path is unsafe") unless safe
        name
      rescue ArgumentError
        raise Error.new("candidate_archive", "candidate archive path is unsafe"), cause: nil
      end

      def reject_file_parent!(paths, name)
        parts = name.split("/")
        1.upto(parts.length - 1) do |count|
          parent = parts.first(count).join("/")
          raise Error.new("candidate_archive", "candidate archive has a file-parent conflict") if
            paths[parent] == :file
        end
        prefix = "#{name}/"
        if paths.any? { |path, _kind| path.start_with?(prefix) }
          raise Error.new("candidate_archive", "candidate archive has a descendant conflict")
        end
      end

      def consume(entry)
        until entry.eof?
          remaining = entry.size - entry.pos
          chunk = entry.read([ CHUNK_BYTES, remaining ].min)
          raise Error.new("candidate_archive", "candidate archive member ended early") if
            chunk.nil? || chunk.empty?
        end
      end

      def read_flags
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
        flags
      end
    end

    private

    def verify_archive!
      path = @prepared.fetch("archive_path")
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      digest = Digest::SHA256.new
      File.open(path, flags) do |file|
        current = file.stat
        fields = %i[dev ino uid mode nlink size]
        unless current.file? && fields.all? do |field|
          current.public_send(field) == @archive_identity.public_send(field)
        end
          raise Error.new("candidate_identity", "candidate archive identity changed")
        end
        while (chunk = file.read(CHUNK_BYTES))
          digest.update(chunk)
        end
      end
      unless digest.hexdigest == @prepared.fetch("archive_sha256")
        raise Error.new("candidate_identity", "candidate archive bytes changed")
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES
      raise Error.new("candidate_identity", "candidate archive is unavailable"), cause: nil
    end

    def validate_input!
      unless SHA.match?(@controller_sha) && SHA.match?(@candidate_sha) &&
             @controller_sha != @candidate_sha
        raise Error.new("candidate_identity", "candidate and controller identities are invalid")
      end
      owned_directory!(@repo_root, "candidate repository")
      resolved = git_output("rev-parse", "--verify", "#{@candidate_sha}^{commit}").strip
      raise Error.new("candidate_identity", "candidate commit is unavailable") unless resolved == @candidate_sha
    end

    def load_module_manifests
      MODULES.to_h do |name|
        bytes = git_output("show", "#{@candidate_sha}:modules/#{name}/manifest.yml")
        raise Error.new("candidate_identity", "module manifest is oversized") if bytes.bytesize > MAX_MANIFEST_BYTES
        manifest = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
        valid = manifest.is_a?(Hash) && manifest["version"].is_a?(String) &&
          manifest["release_sha256"].to_s.match?(DIGEST) &&
          manifest.dig("source", "revision").to_s.match?(SHA)
        raise Error.new("candidate_identity", "module manifest is malformed") unless valid
        [ name, {
          "bytes_sha256" => Digest::SHA256.hexdigest(bytes),
          "version" => manifest.fetch("version"),
          "release_sha256" => manifest.fetch("release_sha256"),
          "source_revision" => manifest.dig("source", "revision")
        } ]
      end
    rescue Psych::Exception, KeyError, TypeError
      raise Error.new("candidate_identity", "module manifest is malformed"), cause: nil
    end

    def admit_identity(value)
      unless value.is_a?(Hash) && value.keys.sort == IDENTITY_KEYS &&
             value.values_at("gem_sha256", "installed_hive_sha256", "module_manifest_sha256",
                             "dependency_closure_sha256", "toolchain_sha256").all? do |digest|
               digest.is_a?(String) && DIGEST.match?(digest)
             end
        raise Error.new("candidate_identity", "installed identity is malformed")
      end
      closure = value.fetch("dependency_closure")
      unless closure.is_a?(Array) && closure.size.between?(1, MAX_CLOSURE_MEMBERS) &&
             closure == closure.sort_by { |row| row.fetch("full_name") } &&
             closure.map { |row| row.fetch("full_name") }.uniq.size == closure.size
        raise Error.new("candidate_identity", "dependency closure is malformed")
      end
      closure.each do |row|
        valid = row.is_a?(Hash) && row.keys.sort == CLOSURE_KEYS &&
          row.values_at("name", "version", "platform", "full_name").all? do |item|
            item.is_a?(String) && item.bytesize.between?(1, 256)
          end && row.fetch("spec_sha256").to_s.match?(DIGEST)
        raise Error.new("candidate_identity", "dependency closure is malformed") unless valid
      end
      toolchain = value.fetch("toolchain")
      unless toolchain.is_a?(Hash) && toolchain.keys.sort == TOOLCHAIN_KEYS &&
             toolchain.values.all? { |item| item.is_a?(String) && item.bytesize.between?(1, 256) }
        raise Error.new("runtime_identity", "toolchain identity is malformed")
      end
      unless digest_json(closure) == value.fetch("dependency_closure_sha256") &&
             digest_json(toolchain) == value.fetch("toolchain_sha256")
        raise Error.new("candidate_identity", "installed identity digest differs")
      end
      canonical_value(value)
    rescue KeyError, TypeError
      raise Error.new("candidate_identity", "installed identity is malformed"), cause: nil
    end

    def digest_json(value) = Digest::SHA256.hexdigest(JSON.generate(canonical_value(value)))

    def canonical_value(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical_value(value.fetch(key)) ] }
      when Array then value.map { |item| canonical_value(item) }
      else value
      end
    end

    def git_output(*arguments)
      stdout, _stderr, status = Open3.capture3("git", "-C", @repo_root, *arguments)
      raise Error.new("candidate_identity", "candidate Git object is unavailable") unless status.success?
      stdout
    rescue SystemCallError
      raise Error.new("candidate_identity", "candidate Git object is unavailable")
    end

    def run_command(argv, _label)
      _stdout, _stderr, status = Open3.capture3(*argv)
      raise Error.new("candidate_archive", "candidate archive command failed") unless status.success?
    rescue SystemCallError
      raise Error.new("candidate_archive", "candidate archive command is unavailable")
    end

    def owned_directory!(path, label)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error.new("path_custody", "#{label} is not an owned directory")
      end
      File.realpath(path)
    rescue Errno::ENOENT, Errno::EACCES
      raise Error.new("path_custody", "#{label} is unavailable")
    end
  end
end
