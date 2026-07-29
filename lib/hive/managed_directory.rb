require "securerandom"
require "digest"
require "hive/errors"
require "hive/managed_directory/native_at"

module Hive
  # Narrow storage primitive for small file-backed stores. Public paths remain
  # lexical, while every filesystem operation below the verified anchor is
  # resolved relative to directory descriptors held for one reentrant session.
  class ManagedDirectory
    class UnsafeError < Hive::ConfigError; end

    private_constant :NativeAt

    class MissingEntry < StandardError; end
    private_constant :MissingEntry

    ACTIVE_SESSIONS_KEY = :hive_managed_directory_sessions
    private_constant :ACTIVE_SESSIONS_KEY

    attr_reader :root

    def initialize(root:, label:, anchor: nil)
      @root = File.expand_path(root).freeze
      @label = label.to_s.freeze
      @anchor = File.expand_path(anchor || nearest_existing_ancestor(@root)).freeze
      unsafe! unless contained?(@root, @anchor)
      @native = NativeAt.new
    rescue NativeAt::Unavailable
      unsafe!
    end

    def prepare!
      with_session(create_root: true) { |_session| nil }
      self
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    end

    def ensure_directory(relative = ".")
      components = relative_components(relative)
      with_session(create_root: true) do |session|
        session.with_directory(components, create: true) { nil }
      end
      absolute(relative)
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
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

      components = relative_components(relative)
      with_session(create_root: false) do |session|
        session.with_directory(components, missing: missing) do |handle|
          enumeration = @native.open_directory(handle.directory, ".")
          begin
            before = directory_stat(enumeration)
            unsafe! unless identity(before) == handle.identity
            enumeration.each_child { |name| yield name }
            unsafe! unless same_identity?(before, directory_stat(enumeration))
          ensure
            enumeration.close
          end
        end
      end
      nil
    rescue MissingEntry
      return nil if missing

      unsafe!
    rescue Errno::ENOENT
      unsafe!
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    end

    def read(relative, max_bytes:, missing: false)
      limit = Integer(max_bytes)
      unsafe! if limit.negative?
      parent_components, name = target_components(relative)

      with_session(create_root: false) do |session|
        session.with_directory(parent_components, missing: missing) do |parent|
          opened = session.open_regular(parent, name, missing: missing)
          next nil unless opened

          file, before = opened
          begin
            unsafe! if before.size > limit
            bytes = file.read(limit + 1)
            bytes = "".b if bytes.nil? && before.size.zero?
            after = file.stat
            unsafe! unless unchanged_file?(before, after)
            unsafe! if bytes.nil? || bytes.bytesize > limit
            unsafe! unless regular_snapshot(before) ==
              session.regular_snapshot_at(parent, name)
            bytes.b.freeze
          ensure
            file.close
          end
        end
      end
    rescue MissingEntry
      return nil if missing

      unsafe!
    rescue Errno::ENOENT
      unsafe!
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    end

    def atomic_write(relative, content, mode: 0o600,
                     expected_digest: nil, max_existing_bytes: nil)
      path = absolute(relative)
      parent_components, name = target_components(relative)
      temporary_name = nil
      temporary_identity = nil

      with_session(create_root: true) do |session|
        session.with_directory(parent_components, create: true) do |parent|
          before = session.regular_snapshot_at(parent, name)
          if expected_digest
            verify_digest_at!(
              session,
              parent,
              name,
              before,
              expected_digest,
              max_bytes: max_existing_bytes
            )
          end

          temporary_name =
            ".#{name}.tmp.#{Process.pid}.#{SecureRandom.hex(6)}"
          flags = File::WRONLY | File::CREAT | File::EXCL
          file = @native.open_file(
            parent.directory,
            temporary_name,
            flags,
            mode: mode
          )
          begin
            created = validate_regular!(file.stat)
            temporary_identity = identity(created)
            file.chmod(mode)
            file.write(content)
            file.flush
            file.fsync
            unsafe! unless temporary_identity == identity(file.stat)
          ensure
            file.close
          end

          unsafe! unless before == session.regular_snapshot_at(parent, name)
          session.verify_binding!(parent)
          @native.renameat(
            parent.directory,
            temporary_name,
            parent.directory,
            name
          )
          temporary_name = nil
          unsafe! unless temporary_identity ==
            session.regular_identity_at(parent, name)
          @native.fsync_directory(parent.directory)
          session.verify_binding!(parent)
        ensure
          session.remove_owned_temporary(
            parent,
            temporary_name,
            temporary_identity
          ) if temporary_name
        end
      end
      path
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    end

    def with_lock(relative, shared: false)
      parent_components, name = target_components(relative)
      lock = nil

      with_session(create_root: true) do |session|
        session.with_directory(parent_components, create: true) do |parent|
          before = session.regular_identity_at(parent, name)
          lock = @native.open_file(
            parent.directory,
            name,
            File::RDWR | File::CREAT,
            mode: 0o600
          )
          validate_regular!(lock.stat)
          lock.chmod(0o600)
          opened = identity(lock.stat)
          unsafe! unless before.nil? || before == opened
          unsafe! unless opened == session.regular_identity_at(parent, name)
          session.verify_binding!(parent)
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          unsafe! unless opened == session.regular_identity_at(parent, name)
          result = yield
          unsafe! unless opened == session.regular_identity_at(parent, name)
          session.verify_binding!(parent)
          result
        end
      end
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    ensure
      lock&.flock(File::LOCK_UN) rescue nil
      lock&.close rescue nil
    end

    def unlink(relative, missing: false, expected_digest: nil,
               max_bytes: nil)
      parent_components, name = target_components(relative)

      result = with_session(create_root: false) do |session|
        session.with_directory(parent_components, missing: missing) do |parent|
          opened = session.open_regular(parent, name, missing: missing)
          next false unless opened

          file, before = opened
          begin
            snapshot = regular_snapshot(before)
            verify_open_digest!(
              file,
              before,
              expected_digest,
              max_bytes: max_bytes
            ) if expected_digest
            unsafe! unless snapshot == session.regular_snapshot_at(parent, name)
            session.verify_binding!(parent)
            @native.unlinkat(parent.directory, name)
            unsafe! if session.regular_identity_at(parent, name)
            @native.fsync_directory(parent.directory)
            session.verify_binding!(parent)
          ensure
            file.close
          end
          true
        end
      end
      result || false
    rescue MissingEntry
      return false if missing

      unsafe!
    rescue Errno::ENOENT
      unsafe!
    rescue Hive::ConfigError
      raise
    rescue SystemCallError, IOError, ArgumentError, TypeError
      unsafe!
    end

    private

    DirectoryHandle = Struct.new(
      :directory,
      :components,
      :identity,
      keyword_init: true
    )
    private_constant :DirectoryHandle

    # Owns the verified descriptor chain for one outer public operation. Nested
    # operations (notably work performed while holding a lock) reuse it.
    class Session
      def initialize(owner, native, create_root:)
        @owner = owner
        @native = native
        @chain = []
        complete = false
        open_root!(create: create_root)
        complete = true
      ensure
        close unless complete
      end

      def close
        @chain.reverse_each do |entry|
          entry.directory.close
        rescue IOError, SystemCallError
          nil
        end
        @chain.clear
      end

      def with_directory(components, create: false, missing: false)
        owned = []
        current = root_directory
        traversed = []

        components.each do |name|
          directory = open_component(
            current,
            name,
            create: create,
            parent_components: traversed
          )
          if directory.nil?
            raise MissingEntry unless missing

            return nil
          end
          owned << directory
          current = directory
          traversed << name
        end

        handle = DirectoryHandle.new(
          directory: current,
          components: components.freeze,
          identity: @owner.__send__(:identity, directory_stat(current))
        )
        verify_binding!(handle)
        entered = true
        yield handle
      ensure
        verify_binding!(handle) if entered
        owned&.reverse_each do |directory|
          directory.close
        rescue IOError, SystemCallError
          nil
        end
      end

      def open_regular(parent, name, missing: false)
        file = @native.open_file(parent.directory, name, File::RDONLY)
        stat = file.stat
        @owner.__send__(:validate_regular!, stat)
        complete = true
        [ file, stat ]
      rescue Errno::ENOENT
        raise MissingEntry unless missing

        nil
      ensure
        file&.close unless complete
      end

      def regular_snapshot_at(parent, name)
        stat = regular_stat_at(parent, name)
        stat && @owner.__send__(:regular_snapshot, stat)
      end

      def regular_identity_at(parent, name)
        stat = regular_stat_at(parent, name)
        stat && @owner.__send__(:identity, stat)
      end

      def verify_binding!(handle)
        verify_root_binding!
        current = root_directory
        opened = []
        handle.components.each do |name|
          current = @native.open_directory(current, name)
          opened << current
        end
        actual = @owner.__send__(:identity, directory_stat(current))
        @owner.__send__(:unsafe!) unless actual == handle.identity
        nil
      ensure
        opened&.reverse_each do |directory|
          directory.close
        rescue IOError, SystemCallError
          nil
        end
      end

      def remove_owned_temporary(parent, name, expected)
        return unless name && expected
        return unless regular_identity_at(parent, name) == expected

        @native.unlinkat(parent.directory, name)
        @native.fsync_directory(parent.directory)
      rescue SystemCallError, Hive::ConfigError
        nil
      end

      private

      ChainEntry = Struct.new(
        :directory,
        :name,
        :identity,
        keyword_init: true
      )

      def regular_stat_at(parent, name)
        file = @native.open_file(parent.directory, name, File::RDONLY)
        stat = file.stat
        @owner.__send__(:validate_regular!, stat)
        stat
      rescue Errno::ENOENT
        nil
      ensure
        file&.close
      end

      def open_root!(create:)
        anchor_before = @owner.__send__(:anchor_stat)
        anchor = @native.open_absolute_directory(
          @owner.__send__(:anchor_path)
        )
        anchor_entry = ChainEntry.new(directory: anchor)
        @chain << anchor_entry
        anchor_opened = directory_stat(anchor)
        @owner.__send__(:unsafe!) unless @owner.__send__(
          :same_identity?,
          anchor_before,
          anchor_opened
        )
        @owner.__send__(:verify_anchor_identity!, anchor_opened)
        anchor_entry.identity = @owner.__send__(:identity, anchor_opened)

        @owner.__send__(:root_components_from_anchor).each do |name|
          parent = @chain.last.directory
          directory = open_root_component(parent, name, create: create)
          entry = ChainEntry.new(directory: directory, name: name)
          @chain << entry
          stat = directory_stat(directory)
          @owner.__send__(:validate_directory!, stat)
          entry.identity = @owner.__send__(:identity, stat)
        end
        verify_root_binding!
      end

      def open_root_component(parent, name, create:)
        directory = @native.open_directory(parent, name)
        complete = true
        directory
      rescue Errno::ENOENT
        raise unless create

        begin
          @native.mkdirat(parent, name, 0o700)
        rescue Errno::EEXIST
          nil
        end
        directory = @native.open_directory(parent, name)
        @native.fsync_directory(parent)
        complete = true
        directory
      ensure
        directory&.close unless complete
      end

      def open_component(parent, name, create:, parent_components:)
        directory = @native.open_directory(parent, name)
        complete = true
        directory
      rescue Errno::ENOENT
        return nil unless create

        parent_handle = DirectoryHandle.new(
          directory: parent,
          components: parent_components.dup.freeze,
          identity: @owner.__send__(:identity, directory_stat(parent))
        )
        verify_binding!(parent_handle)
        begin
          @native.mkdirat(parent, name, 0o700)
        rescue Errno::EEXIST
          nil
        end
        directory = @native.open_directory(parent, name)
        @native.fsync_directory(parent)
        verify_binding!(parent_handle)
        complete = true
        directory
      ensure
        directory&.close unless complete
      end

      def verify_root_binding!
        @owner.__send__(:verify_anchor_identity!, @chain.first.identity)
        current = @chain.first.directory
        opened = []
        @chain.drop(1).each do |entry|
          current = @native.open_directory(current, entry.name)
          opened << current
          actual = @owner.__send__(:identity, directory_stat(current))
          @owner.__send__(:unsafe!) unless actual == entry.identity
        end
        nil
      ensure
        opened&.reverse_each do |directory|
          directory.close
        rescue IOError, SystemCallError
          nil
        end
      end

      def root_directory
        @chain.last.directory
      end

      def directory_stat(directory)
        IO.for_fd(directory.fileno, autoclose: false).stat
      end
    end
    private_constant :Session

    def with_session(create_root:)
      sessions = Thread.current[ACTIVE_SESSIONS_KEY] ||= {}
      return yield sessions.fetch(self) if sessions.key?(self)

      begin
        session = Session.new(self, @native, create_root: create_root)
      rescue Errno::ENOENT
        raise MissingEntry
      end
      sessions[self] = session
      yield session
    ensure
      if session
        sessions.delete(self)
        session.close
      end
      Thread.current[ACTIVE_SESSIONS_KEY] = nil if sessions&.empty?
    end

    def absolute(relative)
      value = validated_relative(relative)
      value == "." ? root : File.join(root, value)
    end

    def relative_components(relative)
      value = validated_relative(relative)
      value == "." ? [] : value.split(File::SEPARATOR)
    end

    def target_components(relative)
      components = relative_components(relative)
      unsafe! if components.empty?

      [ components[0...-1], components.last ]
    end

    def validated_relative(value)
      unsafe! unless value.is_a?(String) && !value.empty?
      components = value.split(File::SEPARATOR, -1)
      unsafe! if value.start_with?(File::SEPARATOR) ||
                 value.include?("\0") ||
                 components.any? { |part| part.empty? || part == ".." } ||
                 (components.include?(".") && value != ".")
      value
    end

    def validate_directory!(stat)
      unsafe! unless stat.directory? && !stat.symlink?
      stat
    end

    def validate_regular!(stat)
      unsafe! unless stat.file? && !stat.symlink? && stat.nlink == 1
      stat
    end

    def regular_snapshot(stat)
      [
        stat.dev, stat.ino, stat.mode, stat.size, stat.mtime, stat.ctime,
        stat.nlink
      ].freeze
    end

    def verify_digest_at!(session, parent, name, snapshot, expected_digest,
                          max_bytes:)
      unsafe! unless snapshot
      opened = session.open_regular(parent, name)
      file, stat = opened
      begin
        unsafe! unless regular_snapshot(stat) == snapshot
        verify_open_digest!(
          file,
          stat,
          expected_digest,
          max_bytes: max_bytes
        )
      ensure
        file.close
      end
      unsafe! unless snapshot == session.regular_snapshot_at(parent, name)
    end

    def verify_open_digest!(file, opened, expected_digest, max_bytes:)
      limit = Integer(max_bytes)
      unsafe! if limit.negative? || opened.size > limit
      file.rewind
      bytes = file.read(limit + 1)
      bytes = "".b if bytes.nil? && opened.size.zero?
      after = file.stat
      unsafe! unless unchanged_file?(opened, after)
      unsafe! if bytes.nil? || bytes.bytesize > limit
      unsafe! unless expected_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
      unsafe! unless Digest::SHA256.hexdigest(bytes) == expected_digest
    rescue ArgumentError, TypeError
      unsafe!
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

    def directory_stat(directory)
      IO.for_fd(directory.fileno, autoclose: false).stat
    end

    def anchor_stat
      stat = File.lstat(@anchor)
      validate_directory!(stat)
    end

    def anchor_path
      @anchor
    end

    def verify_anchor_identity!(expected)
      actual = anchor_stat
      expected_identity = expected.is_a?(Array) ? expected : identity(expected)
      unsafe! unless expected_identity == identity(actual)
      nil
    end

    def root_components_from_anchor
      relative = root.delete_prefix(@anchor).delete_prefix(File::SEPARATOR)
      relative.empty? ? [] : relative.split(File::SEPARATOR)
    end

    def contained?(path, base)
      prefix = base.end_with?(File::SEPARATOR) ?
        base : "#{base}#{File::SEPARATOR}"
      path == base || path.start_with?(prefix)
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

    def unsafe!
      raise UnsafeError, "#{@label} managed directory is unsafe"
    end
  end
end
