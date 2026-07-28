require "securerandom"
require "hive/errors"

module Hive
  # Narrow storage primitive for small file-backed stores. Paths are confined
  # below one lexical root, every managed directory component is lstat-checked,
  # and file descriptors are rebound to the expected inode before use.
  class ManagedDirectory
    class UnsafeError < Hive::ConfigError; end

    attr_reader :root

    def initialize(root:, label:, anchor: nil)
      @root = File.expand_path(root).freeze
      @label = label.to_s.freeze
      @anchor = File.expand_path(anchor || nearest_existing_ancestor(@root)).freeze
      unsafe! unless contained?(@root, @anchor)
    end

    def prepare!
      ensure_path(root)
      self
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError
      unsafe!
    end

    def ensure_directory(relative = ".")
      ensure_path(absolute(relative))
      absolute(relative)
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError
      unsafe!
    end

    def relative_path(path)
      expanded = File.expand_path(path)
      unsafe! unless contained?(expanded, root)

      value = expanded.delete_prefix(root).delete_prefix(File::SEPARATOR)
      value.empty? ? "." : validated_relative(value)
    rescue ArgumentError, TypeError
      unsafe!
    end

    def each_child(relative = ".", missing: false)
      return enum_for(__method__, relative, missing: missing) unless block_given?

      path = absolute(relative)
      before = existing_directory_path(path, missing: missing)
      return nil unless before

      Dir.open(path) do |entries|
        descriptor = IO.for_fd(entries.fileno, autoclose: false)
        unsafe! unless same_identity?(before, descriptor.stat)
        entries.each_child { |name| yield name }
        unsafe! unless same_identity?(before, descriptor.stat)
      end
      unsafe! unless same_identity?(before, validate_directory_path(path))
      nil
    rescue Errno::ENOENT
      unsafe!
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError
      unsafe!
    end

    def read(relative, max_bytes:, missing: false)
      limit = Integer(max_bytes)
      unsafe! if limit.negative?
      path = absolute(relative)
      parent = File.dirname(path)
      existing = existing_read_target(path, missing: missing)
      return nil unless existing

      parent_before, before = existing
      validate_regular!(before)
      unsafe! if before.size > limit

      File.open(path, File::RDONLY | nofollow) do |file|
        opened = file.stat
        unsafe! unless same_identity?(before, opened)
        bytes = file.read(limit + 1)
        after = file.stat
        unsafe! unless unchanged_file?(opened, after)
        unsafe! if bytes.nil? || bytes.bytesize > limit
        unsafe! unless same_identity?(parent_before, validate_directory_path(parent))
        return bytes.b.freeze
      end
    rescue Errno::ENOENT
      unsafe!
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    end

    def atomic_write(relative, content, mode: 0o600)
      path = absolute(relative)
      parent = File.dirname(path)
      parent_before = ensure_path(parent)
      before = existing_regular_identity(path)
      temporary = File.join(
        parent,
        ".#{File.basename(path)}.tmp.#{Process.pid}.#{SecureRandom.hex(6)}"
      )
      temporary_identity = nil
      flags = File::WRONLY | File::CREAT | File::EXCL | nofollow
      File.open(temporary, flags, mode) do |file|
        file.chmod(mode)
        validate_regular!(file.stat)
        file.write(content)
        file.flush
        file.fsync
        temporary_identity = identity(file.stat)
      end
      unsafe! unless same_identity?(parent_before, validate_directory_path(parent))
      unsafe! unless before == existing_regular_identity(path)
      File.rename(temporary, path)
      temporary = nil
      unsafe! unless temporary_identity == existing_regular_identity(path)
      fsync_directory(parent, parent_before)
      path
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    ensure
      remove_owned_temporary(temporary, temporary_identity, parent_before) if temporary
    end

    def with_lock(relative, shared: false)
      path = absolute(relative)
      parent = File.dirname(path)
      parent_before = ensure_path(parent)
      before = existing_regular_identity(path)
      lock = File.open(path, File::RDWR | File::CREAT | nofollow, 0o600)
      validate_regular!(lock.stat)
      lock.chmod(0o600)
      opened = identity(lock.stat)
      unsafe! unless before.nil? || before == opened
      unsafe! unless opened == existing_regular_identity(path)
      unsafe! unless same_identity?(parent_before, validate_directory_path(parent))
      lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
      unsafe! unless opened == existing_regular_identity(path)
      result = yield
      unsafe! unless opened == existing_regular_identity(path)
      unsafe! unless same_identity?(parent_before, validate_directory_path(parent))
      result
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError
      unsafe!
    ensure
      lock&.flock(File::LOCK_UN) rescue nil
      lock&.close rescue nil
    end

    private

    def absolute(relative)
      value = validated_relative(relative)
      value == "." ? root : File.join(root, value)
    end

    def validated_relative(value)
      unsafe! unless value.is_a?(String) && !value.empty?
      components = value.split(File::SEPARATOR, -1)
      unsafe! if value.start_with?(File::SEPARATOR) ||
                 components.any? { |part| part.empty? || part == ".." } ||
                 (components.include?(".") && value != ".")
      value
    end

    def ensure_path(path)
      validate_existing_directory(@anchor)
      paths_between(@anchor, path).each do |candidate|
        begin
          validate_existing_directory(candidate)
        rescue Errno::ENOENT
          parent = File.dirname(candidate)
          parent_before = validate_directory_path(parent)
          begin
            Dir.mkdir(candidate, 0o700)
          rescue Errno::EEXIST
            # A competing creator is acceptable only if it created the exact
            # kind of managed component we require.
          end
          validate_existing_directory(candidate)
          unsafe! unless same_identity?(
            parent_before,
            validate_directory_path(parent)
          )
        end
      end
      validate_directory_path(path)
    end

    def validate_directory_path(path)
      stat = validate_existing_directory(@anchor)
      paths_between(@anchor, path).each do |candidate|
        stat = validate_existing_directory(candidate)
      end
      stat
    end

    def validate_existing_directory(path)
      stat = File.lstat(path)
      unsafe! unless stat.directory? && !stat.symlink?
      stat
    end

    def existing_directory_path(path, missing:)
      validate_directory_path(path)
    rescue Errno::ENOENT
      raise unless missing

      nil
    end

    def existing_read_target(path, missing:)
      [ validate_directory_path(File.dirname(path)), File.lstat(path) ]
    rescue Errno::ENOENT
      raise unless missing

      nil
    end

    def validate_regular!(stat)
      unsafe! unless stat.file? && !stat.symlink? && stat.nlink == 1
      stat
    end

    def existing_regular_identity(path)
      stat = File.lstat(path)
      validate_regular!(stat)
      identity(stat)
    rescue Errno::ENOENT
      nil
    end

    def unchanged_file?(before, after)
      %i[dev ino size mtime ctime nlink].all? do |field|
        before.public_send(field) == after.public_send(field)
      end
    end

    def identity(stat)
      [ stat.dev, stat.ino, stat.mode & 0o170000 ].freeze
    end

    def same_identity?(left, right)
      identity(left) == identity(right)
    end

    def fsync_directory(path, expected)
      unsafe! unless same_identity?(expected, validate_directory_path(path))
      File.open(path, File::RDONLY | nofollow) do |directory|
        unsafe! unless same_identity?(expected, directory.stat)
        directory.fsync
      end
    rescue NotImplementedError, Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
      nil
    end

    def remove_owned_temporary(path, expected, parent_expected)
      return unless expected &&
                    same_identity?(
                      parent_expected,
                      validate_directory_path(File.dirname(path))
                    )
      return unless expected == existing_regular_identity(path)

      File.unlink(path)
    rescue SystemCallError, Hive::ConfigError
      nil
    end

    def paths_between(base, target)
      unsafe! unless contained?(target, base)
      relative = target.delete_prefix(base).delete_prefix(File::SEPARATOR)
      return [] if relative.empty?

      relative.split(File::SEPARATOR).each_with_object([]) do |component, paths|
        paths << File.join(paths.last || base, component)
      end
    end

    def contained?(path, base)
      path == base || path.start_with?("#{base}#{File::SEPARATOR}")
    end

    def nearest_existing_ancestor(path)
      candidate = path
      loop do
        File.lstat(candidate)
        return candidate
      rescue Errno::ENOENT
        parent = File.dirname(candidate)
        unsafe! if parent == candidate
        candidate = parent
      end
    end

    def nofollow
      return File::NOFOLLOW if File.const_defined?(:NOFOLLOW)

      unsafe!
    end

    def unsafe!
      raise UnsafeError, "#{@label} managed directory is unsafe"
    end
  end
end
