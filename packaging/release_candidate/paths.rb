# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "tempfile"
require "tmpdir"

module HiveReleaseCandidate
  SCHEMA_VERSION = 1
  SAFE_SHA = /\A[0-9a-f]{40}\z/.freeze
  SAFE_ATTEMPT = /\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}\z/.freeze

  class Error < StandardError
    attr_reader :exit_code, :kind

    def initialize(message, exit_code: 78, kind: "invalid")
      super(message)
      @exit_code = exit_code
      @kind = kind
    end
  end

  class UsageError < Error
    def initialize(message)
      super(message, exit_code: 64, kind: "usage")
    end
  end

  class UnavailableError < Error
    def initialize(message)
      super(message, exit_code: 69, kind: "unavailable")
    end
  end

  class TemporaryError < Error
    def initialize(message)
      super(message, exit_code: 75, kind: "partial")
    end
  end

  class Paths
    attr_reader :repo_root, :runs_root, :candidate_sha

    def initialize(repo_root:, candidate_sha:, runs_root: nil)
      @repo_root = File.expand_path(repo_root)
      @candidate_sha = validate_sha(candidate_sha)
      @runs_root = File.expand_path(runs_root || File.join(@repo_root, "tmp", "release-candidates"))
      validate_location!
    end

    def candidate_root
      File.join(runs_root, candidate_sha)
    end

    def candidate_dir
      File.join(candidate_root, "candidate")
    end

    def manifest_path
      File.join(candidate_dir, "manifest.json")
    end

    def inputs_dir
      File.join(candidate_root, "inputs")
    end

    def attempts_dir
      File.join(candidate_root, "attempts")
    end

    def attempt_dir(attempt_id)
      File.join(attempts_dir, validate_attempt(attempt_id))
    end

    def evidence_path(attempt_id)
      File.join(attempt_dir(attempt_id), "evidence.json")
    end

    def summary_path(attempt_id)
      File.join(attempt_dir(attempt_id), "summary.md")
    end

    def current_path
      File.join(candidate_root, "current.json")
    end

    def lock_path
      File.join(candidate_root, ".run.lock")
    end

    def relative(path)
      expanded = File.expand_path(path)
      prefix = "#{candidate_root}/"
      raise Error, "path escapes candidate root: #{path}" unless expanded.start_with?(prefix)

      expanded.delete_prefix(prefix)
    end

    def prepare!
      secure_mkdir(runs_root, ancestors_from_repo: true)
      secure_mkdir(candidate_root)
      secure_mkdir(attempts_dir)
      self
    end

    def validate_existing!
      [ runs_root, candidate_root ].each do |path|
        next unless File.exist?(path) || File.symlink?(path)

        stat = File.lstat(path)
        raise Error, "unsafe symlink path: #{path}" if stat.symlink?
        raise Error, "unsafe non-directory path: #{path}" unless stat.directory?
        raise Error, "path is not owned by the current user: #{path}" unless stat.uid == Process.uid
      end
      self
    end

    def with_lock
      prepare!
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(lock_path, flags, 0o600) do |file|
        stat = file.stat
        unless stat.file? && stat.uid == Process.uid && stat.nlink == 1
          raise Error, "candidate lock is not a private regular file"
        end
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          raise TemporaryError, "candidate is already being operated on: #{candidate_sha}"
        end
        begin
          yield
        ensure
          file.flock(File::LOCK_UN) rescue nil
        end
      end
    rescue Errno::ELOOP
      raise Error, "candidate lock cannot be a symlink"
    end

    def new_attempt_id(now: Time.now.utc)
      "#{now.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(6)}"
    end

    def atomic_json(path, value, mode: 0o600)
      atomic_write(path, "#{JSON.pretty_generate(value)}\n", mode: mode)
    end

    def atomic_write(path, content, mode: 0o600)
      parent = File.dirname(path)
      secure_mkdir(parent)
      raise Error, "refusing to replace symlink: #{path}" if File.symlink?(path)

      Tempfile.create([ ".release-candidate-", ".tmp" ], parent, mode: File::RDWR, perm: mode) do |file|
        file.binmode
        file.write(content)
        file.flush
        file.fsync
        File.chmod(mode, file.path)
        File.rename(file.path, path)
      end
      fsync_directory(parent)
      path
    end

    def immutable_tree!(path)
      entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
        .reject { |entry| [ ".", ".." ].include?(File.basename(entry)) }
      entries.sort_by { |entry| -entry.count(File::SEPARATOR) }.each do |entry|
        stat = File.lstat(entry)
        raise Error, "immutable tree contains a symlink: #{entry}" if stat.symlink?
        File.chmod(stat.directory? ? 0o500 : 0o400, entry)
      end
      File.chmod(0o500, path)
      path
    end

    private

    def validate_sha(value)
      normalized = value.to_s.downcase
      unless SAFE_SHA.match?(normalized)
        raise Error, "candidate_sha must be a full 40-character commit SHA"
      end
      normalized
    end

    def validate_attempt(value)
      normalized = value.to_s
      raise UsageError, "invalid attempt ID #{value.inspect}" unless SAFE_ATTEMPT.match?(normalized)

      normalized
    end

    def validate_location!
      repo = begin
        File.realpath(@repo_root)
      rescue SystemCallError => e
        raise Error, "cannot resolve repository root #{@repo_root}: #{e.message}"
      end
      stat = File.lstat(@repo_root)
      raise Error, "repository root cannot be a symlink" if stat.symlink?
      raise Error, "repository root is not owned by the current user" unless stat.uid == Process.uid

      relative = Pathname.new(runs_root).relative_path_from(Pathname.new(repo)).to_s
      if relative == "." || relative.start_with?("../") || Pathname.new(relative).absolute?
        raise Error, "release candidate root must stay beneath the repository"
      end
      unless relative == "tmp/release-candidates" || relative.start_with?("tmp/release-candidates/")
        raise Error, "release candidate root must stay beneath tmp/release-candidates"
      end
      validate_ancestors!(repo, runs_root)
      validate_existing!
    rescue ArgumentError
      raise Error, "release candidate root must stay beneath the repository"
    end

    def secure_mkdir(path, ancestors_from_repo: false)
      return validate_directory!(path) if File.exist?(path) || File.symlink?(path)

      anchor = ancestors_from_repo ? repo_root : candidate_root
      unless path == anchor || path.start_with?("#{anchor}/") || (ancestors_from_repo && path.start_with?("#{repo_root}/"))
        raise Error, "refusing to create path outside the safe root: #{path}"
      end
      parent = File.dirname(path)
      secure_mkdir(parent, ancestors_from_repo: ancestors_from_repo) unless parent == path || File.directory?(parent)
      Dir.mkdir(path, 0o700)
      validate_directory!(path)
    rescue Errno::EEXIST
      validate_directory!(path)
    end

    def validate_ancestors!(anchor, destination)
      relative = Pathname.new(destination).relative_path_from(Pathname.new(anchor))
      current = anchor
      relative.each_filename do |segment|
        current = File.join(current, segment)
        next unless File.exist?(current) || File.symlink?(current)

        validate_directory!(current)
      end
    end

    def validate_directory!(path)
      stat = File.lstat(path)
      raise Error, "unsafe symlink directory: #{path}" if stat.symlink?
      raise Error, "unsafe non-directory path: #{path}" unless stat.directory?
      raise Error, "directory is not owned by the current user: #{path}" unless stat.uid == Process.uid
      path
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    rescue NotImplementedError, Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
      nil
    end
  end
end
