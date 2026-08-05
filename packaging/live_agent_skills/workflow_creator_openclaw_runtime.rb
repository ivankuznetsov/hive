# frozen_string_literal: true

require "digest"
require_relative "workflow_creator"

module HiveLiveAgentProof
  class WorkflowCreatorOpenClawRuntime
    class Error < StandardError; end

    SCHEMA = "hive-openclaw-runtime-install/v1"
    MAX_FILES = 50_000
    MAX_DIRECTORIES = 5_000
    MAX_FILE_BYTES = 268_435_456
    MAX_TOTAL_BYTES = 1_073_741_824
    MAX_PATH_BYTES = 4_096
    MAX_SECONDS = 30.0
    CHUNK_BYTES = 65_536
    SHA256 = /\A[0-9a-f]{64}\z/
    IDENTITY_FIELDS = %i[dev ino uid mode nlink size mtime ctime].freeze
    READ_FLAGS = if defined?(File::NOFOLLOW) && defined?(File::NONBLOCK)
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    end

    class << self
      def capture!(root:, launcher_sha256:)
        new(root:, launcher_sha256:).send(:capture)
      end

      def verify!(runtime_install:, launcher_sha256:)
        expected = WorkflowCreator::Values.capture(runtime_install)
        root = expected.value.fetch("root")
        observed = capture!(root:, launcher_sha256:)
        raise Error, "OpenClaw runtime installation changed" unless
          observed.canonical_bytes == expected.canonical_bytes

        observed.value
      rescue KeyError, TypeError, WorkflowCreator::Values::Error
        raise Error, "OpenClaw runtime installation evidence is invalid", cause: nil
      end
    end

    private_class_method :new

    def initialize(root:, launcher_sha256:)
      @root = File.expand_path(root)
      @launcher_sha256 = launcher_sha256.to_s
      raise Error unless @root == root && SHA256.match?(@launcher_sha256) && READ_FLAGS

      stat = File.lstat(@root)
      raise Error unless File.realpath(@root) == @root && safe_directory?(stat)

      @started = monotonic
      @root_identity = identity(stat)
    rescue SystemCallError, TypeError
      raise Error, "OpenClaw runtime installation is invalid", cause: nil
    end

    def capture
      digest = Digest::SHA256.new
      digest << "hive-openclaw-runtime-tree/v1\0"
      directories = []
      queue = [ [ "", @root ] ]
      file_count = directory_count = total_size = 0

      until queue.empty?
        relative, directory = queue.shift
        stat = File.lstat(directory)
        raise Error unless safe_directory?(stat)
        raise Error if relative.empty? && identity(stat) != @root_identity

        directory_count += 1
        raise Error if directory_count > MAX_DIRECTORIES
        directories << [ directory, identity(stat) ]
        update(digest, "kind" => "directory", "path" => relative, "mode" => stat.mode & 0o777)

        children = Dir.each_child(directory).take(MAX_FILES + MAX_DIRECTORIES + 1).sort
        children.each do |name|
          child_relative = relative.empty? ? name : File.join(relative, name)
          validate_relative!(child_relative)
          child = File.join(@root, child_relative)
          child_stat = File.lstat(child)
          if child_stat.directory?
            queue << [ child_relative, child ]
          else
            file_count += 1
            raise Error if file_count > MAX_FILES
            size = add_node(digest, child, child_relative, child_stat)
            total_size += size
            raise Error if total_size > MAX_TOTAL_BYTES
          end
          time_remaining!
        end
      end

      directories.each { |path, expected| raise Error unless identity(File.lstat(path)) == expected }
      raise Error unless file_count.positive? && total_size.positive?

      WorkflowCreator::Values.capture(
        "schema" => SCHEMA, "schema_version" => 1, "root" => @root,
        "tree_sha256" => digest.hexdigest, "file_count" => file_count,
        "directory_count" => directory_count, "total_size" => total_size,
        "launcher_sha256" => @launcher_sha256
      )
    rescue SystemCallError, WorkflowCreator::Values::Error
      raise Error, "OpenClaw runtime installation is invalid", cause: nil
    end

    def add_node(digest, path, relative, stat)
      if stat.file?
        file_digest = digest_file(path, stat)
        update(
          digest, "kind" => "file", "path" => relative, "mode" => stat.mode & 0o777,
          "size" => stat.size, "sha256" => file_digest
        )
        stat.size
      elsif stat.symlink?
        target = File.readlink(path)
        resolved = File.realpath(path)
        prefix = "#{@root}#{File::SEPARATOR}"
        raise Error unless resolved.start_with?(prefix) && target.bytesize.between?(1, MAX_PATH_BYTES)
        raise Error unless identity(File.lstat(path)) == identity(stat)

        update(digest, "kind" => "symlink", "path" => relative, "target" => target)
        target.bytesize
      else
        raise Error
      end
    end

    def digest_file(path, stat)
      valid = stat.nlink == 1 && stat.uid == Process.uid && (stat.mode & 0o022).zero?
      valid &&= stat.size.between?(0, MAX_FILE_BYTES)
      raise Error unless valid

      digest = Digest::SHA256.new
      File.open(path, READ_FLAGS) do |file|
        opened = file.stat
        raise Error unless identity(opened) == identity(stat)
        while (chunk = file.read(CHUNK_BYTES))
          digest.update(chunk)
          time_remaining!
        end
        raise Error unless identity(file.stat) == identity(opened)
      end
      digest.hexdigest
    end

    def validate_relative!(relative)
      valid = relative.bytesize.between?(1, MAX_PATH_BYTES)
      valid &&= WorkflowCreator::TextSafety.safe_relative_path?(relative.dup.freeze)
      valid &&= File.expand_path(relative, File::SEPARATOR) == File.join(File::SEPARATOR, relative)
      raise Error unless valid
    rescue WorkflowCreator::TextSafety::Error
      raise Error
    end

    def update(digest, record)
      digest << WorkflowCreator::Values.capture(record).canonical_bytes
    end

    def safe_directory?(stat)
      stat.directory? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
    end

    def identity(stat) = IDENTITY_FIELDS.map { |field| stat.public_send(field) }

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def time_remaining!
      elapsed = monotonic - @started
      raise Error unless elapsed.between?(0, MAX_SECONDS)
    end
  end
end
