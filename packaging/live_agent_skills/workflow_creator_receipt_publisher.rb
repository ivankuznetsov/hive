# frozen_string_literal: true

require "fiddle"
require "securerandom"

module HiveLiveAgentProof
  class WorkflowCreatorReceiptPublisher
    class Error < StandardError; end
    class Conflict < Error; end
    class Unsafe < Error; end
    class Unavailable < Error; end
    class Changed < Error; end
    private_constant :Changed

    MAX_RECEIPT_BYTES = 1_048_576
    MAX_DIRECTORY_ENTRIES = 1_024
    FILE_MODE = 0o600
    DIRECTORY_MODE_MASK = 0o022
    Entry = Data.define(:name, :identity, :inode, :bytes, :links)
    Context = Data.define(:staging, :target, :staging_path, :target_path,
                          :staging_identity, :target_identity, :prefix)
    private_constant :Entry, :Context

    def initialize(bundle_directory:, target_name:)
      @bundle_directory = safe_path(bundle_directory)
      @target_name = safe_component(target_name)
      @native = Native.new
    end

    def initialize_receipt(bytes)
      bytes = safe_bytes(bytes)
      with_locked_context do |context|
        begin
          current = settle(context)
          if current
            raise Conflict, "creator evidence initialization conflicts" unless current.bytes == bytes

            return durable_retry(context, current, bytes)
          end

          stage = write_stage(context, bytes)
          begin
            verify_bindings!(context)
            @native.linkat(context.staging, stage.name, context.target, @target_name)
          rescue Errno::EEXIST
            remove_known_stage(context, stage)
            stage = nil
            winner = settle(context)
            raise Conflict, "creator evidence initialization conflicts" unless winner&.bytes == bytes

            return durable_retry(context, winner, bytes)
          end
          remove_linked_stage(context, stage)
          stage = nil
          verify_exact_target!(context, bytes)
          sync_directories(context)
          :initialized
        ensure
          remove_known_stage(context, stage) if stage
        end
      end
    rescue Conflict, Unsafe
      raise
    rescue Changed
      raise Unsafe, "creator evidence state changed during publication", cause: nil
    rescue SystemCallError, IOError, Fiddle::DLError, NotImplementedError
      raise Unavailable, "creator evidence storage operation failed", cause: nil
    end

    def replace_receipt(expected_bytes, desired_bytes)
      expected = safe_bytes(expected_bytes)
      desired = safe_bytes(desired_bytes)
      with_locked_context do |context|
        begin
          current = settle(context)
          raise Conflict, "creator evidence replacement has no expected target" unless current
          return durable_retry(context, current, desired) if current.bytes == desired
          raise Conflict, "creator evidence replacement conflicts" unless current.bytes == expected

          stage = write_stage(context, desired)
          verify_bindings!(context)
          revalidate_expected!(context, current, expected)
          @native.renameat(context.staging, stage.name, context.target, @target_name)
          stage = nil
          verify_exact_target!(context, desired)
          sync_directories(context)
          :replaced
        ensure
          remove_known_stage(context, stage) if stage
        end
      end
    rescue Conflict, Unsafe
      raise
    rescue Changed
      raise Unsafe, "creator evidence state changed during publication", cause: nil
    rescue SystemCallError, IOError, Fiddle::DLError, NotImplementedError
      raise Unavailable, "creator evidence storage operation failed", cause: nil
    end

    private

    def with_context
      context = open_context
      yield context
    ensure
      close_descriptors(context&.target, context&.staging, primary: $!)
    end

    def with_locked_context
      with_context do |context|
        @native.lock(context.target)
        locked = true
        begin
          yield context
        ensure
          primary = $!
          begin
            @native.unlock(context.target) if locked
          rescue StandardError => cleanup_error
            raise cleanup_error unless primary
          end
        end
      end
    end

    def open_context
      completed = false
      staging_path = File.dirname(@bundle_directory)
      target_leaf = safe_component(File.basename(@bundle_directory))
      staging = @native.open_directory(staging_path)
      target = @native.open_directory_at(staging, target_leaf)
      staging_identity = directory_identity(staging.stat, private: false)
      target_identity = directory_identity(target.stat, private: true)
      raise Unsafe, "creator evidence directories cross filesystems" unless
        staging_identity.fetch(:dev) == target_identity.fetch(:dev)

      prefix = ".hive-creator-#{target_identity.fetch(:dev).to_s(16)}-" \
               "#{target_identity.fetch(:ino).to_s(16)}-"
      context = Context.new(staging:, target:, staging_path:, target_path: @bundle_directory,
                            staging_identity:, target_identity:, prefix:)
      verify_bindings!(context)
      completed = true
      context
    rescue Errno::ELOOP, Errno::ENOTDIR
      raise Unsafe, "creator evidence directory binding is unsafe", cause: nil
    ensure
      close_descriptors(target, staging, primary: $!) unless completed
    end

    def settle(context)
      4.times do
        target = read_optional(context.target, @target_name)
        stages = staging_entries(context)
        if target.nil?
          return nil if stages.empty?
          raise Unsafe, "creator evidence staging state is ambiguous" unless stages.length == 1
          stage = stages.first
          raise Unsafe, "creator evidence staging link state is unsafe" unless stage.links == 1

          remove_entry(context.staging, stage.name)
          @native.fsync(context.staging)
          next
        end
        if stages.empty?
          return target if target.links == 1
          next if target.links == 2
          raise Unsafe, "creator evidence target link state is unsafe"
        end
        raise Unsafe, "creator evidence staging state is ambiguous" unless stages.length == 1
        stage = stages.first
        if stage.links == 1
          raise Unsafe, "creator evidence staging link state is unsafe" unless target.links == 1

          remove_entry(context.staging, stage.name)
          @native.fsync(context.staging)
          next
        end
        linked = target.links == 2 && stage.links == 2 && target.inode == stage.inode &&
                 target.bytes == stage.bytes
        raise Unsafe, "creator evidence linked state is unsafe" unless linked

        remove_entry(context.staging, stage.name)
        sync_directories(context)
      rescue Changed, Errno::ENOENT
        next
      end
      raise Unsafe, "creator evidence state did not stabilize"
    end

    def close_descriptors(*descriptors, primary:)
      cleanup_error = nil
      descriptors.compact.each do |descriptor|
        next if descriptor.closed?

        begin
          @native.close(descriptor)
        rescue StandardError => error
          cleanup_error ||= error
        end
      end
      raise cleanup_error if cleanup_error && !primary
    end

    def write_stage(context, bytes)
      name = "#{context.prefix}#{SecureRandom.hex(16)}"
      file = @native.create_file_at(context.staging, name, FILE_MODE)
      begin
        offset = 0
        offset += file.write(bytes.byteslice(offset..)) while offset < bytes.bytesize
        @native.fsync(file)
        stat = file.stat
        validate_file!(stat, links: 1)
      ensure
        file.close
      end
      entry = read_entry(context.staging, name)
      raise Unsafe, "creator evidence staging bytes changed" unless entry.bytes == bytes

      entry
    rescue StandardError => error
      begin
        remove_entry(context.staging, name) if name
      rescue SystemCallError, IOError
        nil
      end
      raise error
    end

    def staging_entries(context)
      names = @native.entries(context.staging, MAX_DIRECTORY_ENTRIES)
      names.grep_v(/\A\.\.?\z/).select { |name| name.start_with?(context.prefix) }.filter_map do |name|
        read_entry(context.staging, name)
      rescue Errno::ENOENT
        nil
      rescue Errno::ELOOP, Errno::ENXIO
        raise Unsafe, "creator evidence staging entry type is unsafe", cause: nil
      end
    end

    def read_optional(directory, name)
      read_entry(directory, name)
    rescue Errno::ENOENT
      nil
    rescue Errno::ELOOP, Errno::ENXIO
      raise Unsafe, "creator evidence entry type is unsafe", cause: nil
    end

    def read_entry(directory, name)
      file = @native.open_file_at(directory, name)
      before = file.stat
      validate_file!(before)
      content = file.read(MAX_RECEIPT_BYTES + 1)
      raise Unsafe, "creator evidence receipt exceeds the size limit" if content.bytesize > MAX_RECEIPT_BYTES
      after = file.stat
      raise Changed, "creator evidence entry changed" unless file_identity(before) == file_identity(after)

      Entry.new(name:, identity: file_identity(after), inode: inode_identity(after),
                bytes: content.b.freeze, links: after.nlink)
    ensure
      file&.close
    end

    def revalidate_expected!(context, expected_entry, expected_bytes)
      current = read_entry(context.target, @target_name)
      valid = current.identity == expected_entry.identity && current.bytes == expected_bytes && current.links == 1
      raise Conflict, "creator evidence replacement target changed" unless valid
      verify_bindings!(context)
    end

    def verify_exact_target!(context, bytes)
      current = read_entry(context.target, @target_name)
      raise Unsafe, "creator evidence published target is not stable" unless current.links == 1 && current.bytes == bytes

      current
    end

    def durable_retry(context, entry, bytes)
      raise Conflict, "creator evidence target conflicts" unless entry.bytes == bytes && entry.links == 1
      file = @native.open_file_at(context.target, @target_name)
      validate_file!(file.stat, links: 1)
      @native.fsync(file)
      raise Changed, "creator evidence target changed" unless read_entry(context.target, @target_name).bytes == bytes
      sync_directories(context)
      :stable
    ensure
      file&.close
    end

    def remove_linked_stage(context, stage)
      remove_entry(context.staging, stage.name)
    rescue Errno::ENOENT
      verify_exact_target!(context, stage.bytes)
    end

    def remove_known_stage(context, stage)
      return unless stage
      current = read_optional(context.staging, stage.name)
      return unless current && current.inode == stage.inode

      remove_entry(context.staging, stage.name)
      @native.fsync(context.staging)
    rescue Errno::ENOENT, Unsafe, Unavailable, SystemCallError, IOError
      nil
    end

    def remove_entry(directory, name)
      @native.unlinkat(directory, name)
    end

    def sync_directories(context)
      verify_bindings!(context)
      @native.fsync(context.target)
      @native.fsync(context.staging)
    end

    def verify_bindings!(context)
      staging = File.lstat(context.staging_path)
      target = File.lstat(context.target_path)
      valid = directory_identity(staging, private: false) == context.staging_identity &&
              directory_identity(target, private: true) == context.target_identity
      raise Unsafe, "creator evidence parent binding changed" unless valid
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      raise Unsafe, "creator evidence parent binding changed", cause: nil
    end

    def directory_identity(stat, private:)
      valid = stat.directory? && stat.uid == Process.uid
      valid &&= (stat.mode & DIRECTORY_MODE_MASK).zero?
      valid &&= (stat.mode & 0o077).zero? if private
      raise Unsafe, "creator evidence directory is unsafe" unless valid

      { dev: stat.dev, ino: stat.ino, uid: stat.uid, mode: stat.mode }
    end

    def validate_file!(stat, links: nil)
      valid = stat.file? && stat.uid == Process.uid && (stat.mode & 0o777) == FILE_MODE
      valid &&= stat.nlink == links if links
      valid &&= stat.nlink.between?(1, 2)
      raise Unsafe, "creator evidence entry is not an owned private regular file" unless valid
    end

    def file_identity(stat)
      [ stat.dev, stat.ino, stat.uid, stat.mode, stat.nlink, stat.size,
        stat.mtime.to_r, stat.ctime.to_r ]
    end

    def inode_identity(stat)
      [ stat.dev, stat.ino ]
    end

    def safe_path(value)
      path = value.to_str
      raise Unsafe, "creator evidence directory path is unsafe" unless
        path.valid_encoding? && !path.include?("\0") && path.bytesize.between?(1, 4_096)

      File.expand_path(path)
    rescue NoMethodError, TypeError, ArgumentError
      raise Unsafe, "creator evidence directory path is unsafe", cause: nil
    end

    def safe_component(value)
      component = value.to_str
      valid = component.valid_encoding? && component.bytesize.between?(1, 255) &&
              !component.include?("\0") && component != "." && component != ".." &&
              !component.include?(File::SEPARATOR)
      raise Unsafe, "creator evidence path component is unsafe" unless valid

      component
    rescue NoMethodError, TypeError
      raise Unsafe, "creator evidence path component is unsafe", cause: nil
    end

    def safe_bytes(value)
      bytes = value.to_str.b
      raise Unsafe, "creator evidence receipt exceeds the size limit" if bytes.bytesize > MAX_RECEIPT_BYTES

      bytes.freeze
    rescue NoMethodError, TypeError
      raise Unsafe, "creator evidence receipt bytes are invalid", cause: nil
    end

    class Native
      LOCK_TIMEOUT_SECONDS = 2.0
      LOCK_RETRY_SECONDS = 0.01
      FLAGS = {
        linux: { directory: 0o200000 | 0o400000 | 0o2000000 | 0o4000,
                 read: 0o400000 | 0o2000000 | 0o4000,
                 create: 0o1 | 0o100 | 0o200 | 0o400000 | 0o2000000 | 0o4000 },
        darwin: { directory: 0x100000 | 0x0100 | 0x1000000 | 0x0004,
                  read: 0x0100 | 0x1000000 | 0x0004,
                  create: 0x0001 | 0x0200 | 0x0800 | 0x0100 | 0x1000000 | 0x0004 }
      }.freeze

      def initialize
        platform = RUBY_PLATFORM.include?("darwin") ? :darwin : :linux if
          RUBY_PLATFORM.include?("darwin") || RUBY_PLATFORM.include?("linux")
        raise NotImplementedError, "unsupported creator evidence platform" unless platform

        @flags = FLAGS.fetch(platform)
        handle = Fiddle::Handle::DEFAULT
        @open = function(handle, "open", [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT ])
        @openat = function(handle, "openat", [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP,
                                               Fiddle::TYPE_INT, Fiddle::TYPE_INT ])
        @linkat = function(handle, "linkat", [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP,
                                               Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ])
        @renameat = function(handle, "renameat", [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP,
                                                   Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP ])
        @unlinkat = function(handle, "unlinkat", [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ])
        @flock = function(handle, "flock", [ Fiddle::TYPE_INT, Fiddle::TYPE_INT ])
      end

      def open_directory(path)
        io(call_fd(@open, path, @flags.fetch(:directory), 0), "r")
      end

      def open_directory_at(directory, name)
        io(call_fd(@openat, directory.fileno, name, @flags.fetch(:directory), 0), "r")
      end

      def open_file_at(directory, name)
        io(call_fd(@openat, directory.fileno, name, @flags.fetch(:read), 0), "rb")
      end

      def create_file_at(directory, name, mode)
        io(call_fd(@openat, directory.fileno, name, @flags.fetch(:create), mode), "wb")
      end

      def linkat(source_directory, source_name, target_directory, target_name)
        call_zero(@linkat, source_directory.fileno, source_name,
                  target_directory.fileno, target_name, 0)
      end

      def renameat(source_directory, source_name, target_directory, target_name)
        call_zero(@renameat, source_directory.fileno, source_name,
                  target_directory.fileno, target_name)
      end

      def unlinkat(directory, name)
        call_zero(@unlinkat, directory.fileno, name, 0)
      end

      def entries(directory, limit)
        duplicate = directory.dup
        stream = Dir.for_fd(duplicate.fileno)
        duplicate.autoclose = false
        entries = stream.each_child.take(limit + 1)
        raise Unsafe, "creator evidence staging enumeration exceeds the limit" if entries.length > limit

        entries
      ensure
        stream&.close
        duplicate&.close if duplicate&.autoclose?
      end

      def fsync(io)
        io.fsync
      end

      def lock(directory)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_TIMEOUT_SECONDS
        loop do
          result = @flock.call(directory.fileno, File::LOCK_EX | File::LOCK_NB)
          return if result.zero?

          error = SystemCallError.new("native creator evidence lock", Fiddle.last_error)
          raise error unless error.is_a?(Errno::EWOULDBLOCK) || error.is_a?(Errno::EAGAIN)
          raise Errno::ETIMEDOUT, "creator evidence lock wait exceeded" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep LOCK_RETRY_SECONDS
        end
      end

      def unlock(directory)
        call_zero(@flock, directory.fileno, File::LOCK_UN)
      end

      def close(io)
        io.close
      end

      private

      def function(handle, name, arguments)
        Fiddle::Function.new(handle[name], arguments, Fiddle::TYPE_INT)
      end

      def call_fd(function, *arguments)
        result = function.call(*arguments)
        raise SystemCallError.new("native creator evidence open", Fiddle.last_error) if result.negative?

        result
      end

      def call_zero(function, *arguments)
        result = function.call(*arguments)
        raise SystemCallError.new("native creator evidence operation", Fiddle.last_error) unless result.zero?

        result
      end

      def io(descriptor, mode)
        IO.for_fd(descriptor, mode, autoclose: true)
      end
    end
    private_constant :Native
  end
end
