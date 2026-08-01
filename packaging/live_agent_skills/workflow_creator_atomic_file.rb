require "fiddle"
require "securerandom"

module HiveLiveAgentProof
  # Descriptor-relative publication for the exact workflow-creator bundle.
  # Temporary entries live beside the bundle directory, never inside it, so a
  # hard-killed writer cannot poison the bundle's exact four-file inventory.
  class WorkflowCreatorAtomicFile
    class Unsafe < StandardError; end
    class Unavailable < StandardError; end

    class NativeAt
      PLATFORM_FLAGS =
        if RUBY_PLATFORM.include?("linux")
          { directory: 0o200000, cloexec: 0o2000000 }.freeze
        elsif RUBY_PLATFORM.include?("darwin")
          { directory: 0x00100000, cloexec: 0x01000000 }.freeze
        end

      def initialize
        raise Unavailable, "descriptor-relative publication is unsupported" unless
          PLATFORM_FLAGS && Dir.respond_to?(:for_fd) &&
          File.const_defined?(:NOFOLLOW) && Fiddle.respond_to?(:last_error=)

        handle = Fiddle::Handle::DEFAULT
        integer = Fiddle::TYPE_INT
        pointer = Fiddle::TYPE_VOIDP
        @openat = function(handle, "openat", [ integer, pointer, integer ])
        @openat_with_mode = function(
          handle, "openat", [ integer, pointer, integer, integer ]
        )
        @renameat = function(
          handle, "renameat", [ integer, pointer, integer, pointer ]
        )
        @linkat = function(
          handle, "linkat", [ integer, pointer, integer, pointer, integer ]
        )
        @unlinkat = function(handle, "unlinkat", [ integer, pointer, integer ])
      rescue Fiddle::DLError, NameError, TypeError
        raise Unavailable, "descriptor-relative publication is unavailable"
      end

      def open_absolute_directory(path)
        flags = File::RDONLY |
                PLATFORM_FLAGS.fetch(:directory) |
                PLATFORM_FLAGS.fetch(:cloexec) |
                File::NOFOLLOW
        fd = IO.sysopen(path, flags)
        directory = Dir.for_fd(fd)
        directory.close_on_exec = true if directory.respond_to?(:close_on_exec=)
        directory
      rescue SystemCallError, IOError, ArgumentError
        IO.for_fd(fd).close if fd
        raise
      end

      def open_file(directory, name, flags, mode: nil)
        component!(name)
        native_flags = Integer(flags) |
                       PLATFORM_FLAGS.fetch(:cloexec) |
                       File::NOFOLLOW
        fd = if mode
               call(
                 @openat_with_mode,
                 directory.fileno,
                 name,
                 native_flags,
                 Integer(mode),
                 operation: "openat"
               )
        else
               call(
                 @openat,
                 directory.fileno,
                 name,
                 native_flags,
                 operation: "openat"
               )
        end
        file = File.for_fd(fd)
        file.close_on_exec = true
        file
      rescue SystemCallError, IOError, ArgumentError, TypeError
        IO.for_fd(fd).close if fd
        raise
      end

      def renameat(source_directory, source_name, target_directory, target_name)
        component!(source_name)
        component!(target_name)
        call(
          @renameat,
          source_directory.fileno,
          source_name,
          target_directory.fileno,
          target_name,
          operation: "renameat"
        )
        nil
      end

      def linkat(source_directory, source_name, target_directory, target_name)
        component!(source_name)
        component!(target_name)
        call(
          @linkat,
          source_directory.fileno,
          source_name,
          target_directory.fileno,
          target_name,
          0,
          operation: "linkat"
        )
        nil
      end

      def unlinkat(directory, name)
        component!(name)
        call(@unlinkat, directory.fileno, name, 0, operation: "unlinkat")
        nil
      end

      private

      def function(handle, name, argument_types)
        Fiddle::Function.new(
          handle[name],
          argument_types,
          Fiddle::TYPE_INT,
          need_gvl: true
        )
      end

      def call(function, *arguments, operation:)
        Fiddle.last_error = 0
        result = function.call(*arguments)
        return result unless result == -1

        raise SystemCallError.new(operation, Fiddle.last_error)
      end

      def component!(value)
        unless value.is_a?(String) && !value.empty? &&
               !value.include?("/") && !value.include?("\0") &&
               !%w[. ..].include?(value)
          raise ArgumentError, "unsafe directory component"
        end
      end
    end

    def initialize(path:, writer:, before_publish:, after_link:, rename_gate:,
                   link_gate:, directory_sync:, expected_parent_identity: nil,
                   native: nil)
      @path = File.expand_path(path)
      @parent_path = File.dirname(@path)
      @staging_path = File.dirname(@parent_path)
      @target_name = File.basename(@path)
      @writer = writer
      @before_publish = before_publish
      @after_link = after_link
      @rename_gate = rename_gate
      @link_gate = link_gate
      @directory_sync = directory_sync
      @expected_parent_identity = expected_parent_identity
      @native = native || NativeAt.new
    end

    def write(bytes, replace:)
      target = @native.open_absolute_directory(@parent_path)
      staging = @native.open_absolute_directory(@staging_path)
      target_identity = directory_identity(target)
      staging_identity = directory_identity(staging)
      validate_target!(target_identity)
      validate_staging!(staging_identity)
      validate_expected_target!(target_identity)
      unless target_identity.fetch(:dev) == staging_identity.fetch(:dev)
        raise Unsafe, "staging and evidence directories are on different filesystems"
      end

      temporary_name = temporary_name()
      temporary_identity = write_temporary(staging, temporary_name, bytes)
      source_label = File.join(@staging_path, temporary_name)
      @before_publish.call(source_label, @path)
      (replace ? @rename_gate : @link_gate).call(source_label, @path)
      verify_binding!(target_identity)
      verify_entry!(staging, temporary_name, temporary_identity, bytes)

      if replace
        @native.renameat(staging, temporary_name, target, @target_name)
        temporary_name = nil
      else
        begin
          @native.linkat(staging, temporary_name, target, @target_name)
        rescue Errno::EEXIST
          recovered = recover_linked_initialization!(
            target,
            staging,
            target_identity,
            staging_identity,
            bytes
          )
          return @path if recovered

          raise
        end
        @after_link.call(source_label, @path)
        @native.unlinkat(staging, temporary_name)
        temporary_name = nil
      end

      verify_entry!(target, @target_name, temporary_identity, bytes)
      sync_directories!(target, staging, target_identity, staging_identity)
      verify_binding!(target_identity)
      @path
    ensure
      remove_temporary(staging, temporary_name) if staging && temporary_name
      staging&.close
      target&.close
    end

    private

    def write_temporary(directory, name, bytes)
      file = @native.open_file(
        directory,
        name,
        File::RDWR | File::CREAT | File::EXCL,
        mode: 0o600
      )
      begin
        file.binmode
        before = inode_identity(file.stat)
        validate_file!(file.stat, expected_links: 1)
        @writer.call(file, bytes)
        file.flush
        file.fsync
        after = file.stat
        unless before == inode_identity(after)
          raise Unsafe, "temporary evidence file changed while writing"
        end

        file_identity(after)
      ensure
        file.close
      end
    end

    def verify_entry!(directory, name, expected_identity, bytes)
      file = @native.open_file(directory, name, File::RDONLY)
      begin
        file.binmode
        stat = file.stat
        validate_file!(stat, expected_links: 1)
        unless file_identity(stat) == expected_identity &&
               file.read(bytes.bytesize + 1) == bytes.b
          raise Unsafe, "published evidence bytes or identity changed"
        end
      ensure
        file.close
      end
    end

    def verify_binding!(expected)
      stat = File.lstat(@parent_path)
      actual = {
        dev: stat.dev,
        ino: stat.ino,
        uid: stat.uid,
        mode: stat.mode & 0o7777,
        directory: stat.directory?,
        symlink: stat.symlink?
      }
      unless actual == expected
        raise Unsafe, "evidence directory changed during publication"
      end
    rescue Errno::ENOENT
      raise Unsafe, "evidence directory changed during publication"
    end

    def validate_target!(identity)
      return if identity.fetch(:directory) && !identity.fetch(:symlink) &&
                identity.fetch(:uid) == Process.uid &&
                identity.fetch(:mode) == 0o700

      raise Unsafe, "evidence directory is unsafe"
    end

    def validate_staging!(identity)
      private_directory = (identity.fetch(:mode) & 0o022).zero?
      sticky_directory = (identity.fetch(:mode) & 0o1000).positive?
      return if identity.fetch(:directory) && !identity.fetch(:symlink) &&
                (private_directory || sticky_directory)

      raise Unsafe, "staging directory is unsafe"
    end

    def validate_expected_target!(identity)
      return unless @expected_parent_identity
      return if identity.values_at(:dev, :ino, :uid) ==
                @expected_parent_identity.values_at(:dev, :ino, :uid)

      raise Unsafe, "validated evidence directory changed before publication"
    end

    def validate_file!(stat, expected_links:)
      return if safe_file?(stat, expected_links: expected_links)

      raise Unsafe, "evidence file is unsafe"
    end

    def directory_identity(directory)
      stat = IO.for_fd(directory.fileno, autoclose: false).stat
      {
        dev: stat.dev,
        ino: stat.ino,
        uid: stat.uid,
        mode: stat.mode & 0o7777,
        directory: stat.directory?,
        symlink: stat.symlink?
      }
    end

    def file_identity(stat)
      { dev: stat.dev, ino: stat.ino, uid: stat.uid, size: stat.size }
    end

    def inode_identity(stat)
      { dev: stat.dev, ino: stat.ino, uid: stat.uid }
    end

    def same_identity?(left, right)
      left.values_at(:dev, :ino) == right.values_at(:dev, :ino)
    end

    def sync_directories!(target, staging, target_identity, staging_identity)
      @directory_sync.call(target, @parent_path)
      unless same_identity?(target_identity, staging_identity)
        @directory_sync.call(staging, @staging_path)
      end
    end

    def recover_linked_initialization!(target, staging, target_identity,
                                       staging_identity, bytes)
      target_file = @native.open_file(target, @target_name, File::RDONLY)
      target_file.binmode
      target_stat = target_file.stat
      return false unless safe_file?(target_stat, expected_links: 2)

      expected = file_identity(target_stat)
      return false unless target_file.read(bytes.bytesize + 1) == bytes.b

      matching = staging.children.filter_map do |name|
        next unless name.start_with?(temporary_prefix)

        matching_link_name(staging, name, expected, bytes)
      end
      unless matching.length == 1
        raise Unsafe, "linked initial evidence cannot be recovered"
      end

      @native.unlinkat(staging, matching.fetch(0))
      verify_entry!(target, @target_name, expected, bytes)
      sync_directories!(target, staging, target_identity, staging_identity)
      verify_binding!(target_identity)
      true
    rescue Errno::ENOENT
      false
    ensure
      target_file&.close
    end

    def matching_link_name(directory, name, expected, bytes)
      file = @native.open_file(directory, name, File::RDONLY)
      file.binmode
      stat = file.stat
      return unless safe_file?(stat, expected_links: 2)
      return unless file_identity(stat) == expected
      return unless file.read(bytes.bytesize + 1) == bytes.b

      name
    ensure
      file&.close
    end

    def safe_file?(stat, expected_links:)
      stat.file? && !stat.symlink? && stat.uid == Process.uid &&
        stat.nlink == expected_links && (stat.mode & 0o777) == 0o600
    end

    def temporary_name
      "#{temporary_prefix}#{Process.pid}.#{SecureRandom.hex(8)}"
    end

    def temporary_prefix
      ".#{File.basename(@parent_path)}.#{@target_name}.tmp."
    end

    def remove_temporary(directory, name)
      @native.unlinkat(directory, name)
    rescue Errno::ENOENT
      nil
    end
  end
end
