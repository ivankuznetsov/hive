require "fiddle"

module Hive
  class ManagedDirectory
    # Minimal libc adapter for descriptor-relative managed-directory operations.
    # Ruby exposes neither the *at family nor O_DIRECTORY, so the two supported
    # POSIX platforms supply only their open flag values here; syscall numbers
    # and descriptor paths are deliberately not used.
    class NativeAt
      class Unavailable < StandardError; end

      def self.platform_flags(platform)
        if platform.include?("linux")
          { directory: 0o200000, cloexec: 0o2000000 }.freeze
        elsif platform.include?("darwin")
          { directory: 0x00100000, cloexec: 0x01000000 }.freeze
        end
      end

      PLATFORM_FLAGS = platform_flags(RUBY_PLATFORM)
      EXCHANGE_FLAG = 0x00000002
      NOREPLACE_FLAG =
        RUBY_PLATFORM.include?("darwin") ?
          0x00000004 : 0x00000001

      def initialize
        raise Unavailable, "unsupported platform" unless PLATFORM_FLAGS
        verify_runtime_capabilities!

        @nofollow = file_constant(:NOFOLLOW)
        @cloexec = PLATFORM_FLAGS.fetch(:cloexec)
        @directory = PLATFORM_FLAGS.fetch(:directory)
        handle = Fiddle::Handle::DEFAULT
        integer = Fiddle::TYPE_INT
        pointer = Fiddle::TYPE_VOIDP
        @openat = function(handle, "openat", [ integer, pointer, integer ])
        @openat_with_mode = function(
          handle,
          "openat",
          [ integer, pointer, integer, integer ]
        )
        @mkdirat = function(
          handle,
          "mkdirat",
          [ integer, pointer, integer ]
        )
        @renameat = function(
          handle,
          "renameat",
          [ integer, pointer, integer, pointer ]
        )
        @exchangeat = optional_function(
          handle,
          RUBY_PLATFORM.include?("darwin") ? "renameatx_np" : "renameat2",
          [ integer, pointer, integer, pointer, integer ]
        )
        @futimens = function(
          handle,
          "futimens",
          [ integer, pointer ]
        )
        @unlinkat = function(
          handle,
          "unlinkat",
          [ integer, pointer, integer ]
        )
      rescue Fiddle::DLError, NameError, TypeError
        raise Unavailable, "required POSIX capability is unavailable"
      end

      def open_absolute_directory(path)
        fd = IO.sysopen(
          path,
          File::RDONLY | @directory | @nofollow | @cloexec
        )
        directory_from_fd(fd)
      rescue SystemCallError, IOError, ArgumentError
        close_fd(fd)
        raise
      end

      def open_directory(directory, name)
        component!(name, allow_dot: true)
        fd = call_openat(
          directory.fileno,
          name,
          File::RDONLY | @directory | @nofollow | @cloexec
        )
        directory_from_fd(fd)
      rescue SystemCallError, IOError, ArgumentError
        close_fd(fd)
        raise
      end

      def open_file(directory, name, flags, mode: nil)
        component!(name)
        native_flags = Integer(flags) | @nofollow | @cloexec
        fd = call_openat(directory.fileno, name, native_flags, mode: mode)
        file_from_fd(fd)
      rescue SystemCallError, IOError, ArgumentError, TypeError
        close_fd(fd)
        raise
      end

      def mkdirat(directory, name, mode)
        component!(name)
        call(@mkdirat, directory.fileno, name, Integer(mode), operation: "mkdirat")
        nil
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

      # Atomically swaps two existing sibling entries. Linux and Darwin expose
      # different libc names for the same required primitive. Callers must not
      # emulate this with two ordinary renames: the gap would let a retired
      # writer recreate the legacy path.
      def exchangeat(directory, first_name, second_name)
        component!(first_name)
        component!(second_name)
        raise Unavailable, "atomic exchange capability is unavailable" unless
          @exchangeat

        call(
          @exchangeat,
          directory.fileno,
          first_name,
          directory.fileno,
          second_name,
          EXCHANGE_FLAG,
          operation: "atomic exchange"
        )
        nil
      end

      # Atomically installs one sibling name only when the destination remains
      # absent. Linux renameat2 and Darwin renameatx_np expose this guarantee
      # with platform-specific flags but the same libc signature.
      def rename_noreplaceat(
        directory, source_name, destination_name
      )
        component!(source_name)
        component!(destination_name)
        unless @exchangeat
          raise Unavailable,
                "atomic no-replace rename capability is unavailable"
        end

        call(
          @exchangeat,
          directory.fileno,
          source_name,
          directory.fileno,
          destination_name,
          NOREPLACE_FLAG,
          operation: "atomic no-replace rename"
        )
        nil
      end

      def unlinkat(directory, name)
        component!(name)
        call(@unlinkat, directory.fileno, name, 0, operation: "unlinkat")
        nil
      end

      def fsync_directory(directory)
        IO.for_fd(directory.fileno, autoclose: false).fsync
      rescue NotImplementedError, Errno::EINVAL, Errno::ENOTSUP
        nil
      end

      def set_file_mtime(file, value)
        time = value.is_a?(Time) ? value : Time.at(value)
        timespec = [
          time.to_i, time.nsec,
          time.to_i, time.nsec
        ].pack("l!4")
        call(
          @futimens,
          file.fileno,
          timespec,
          operation: "futimens"
        )
        nil
      end

      private

      def verify_runtime_capabilities!
        available =
          Fiddle.respond_to?(:last_error=) &&
          Dir.respond_to?(:for_fd) &&
          Dir.instance_methods.include?(:fileno) &&
          File.respond_to?(:for_fd) &&
          File.instance_methods.include?(:chmod) &&
          IO.respond_to?(:for_fd) &&
          IO.instance_methods.include?(:close_on_exec=) &&
          IO.instance_methods.include?(:fsync)
        raise Unavailable, "required descriptor capability is unavailable" unless available
      end

      def file_constant(name)
        constants = File::Constants
        raise Unavailable, "missing #{name}" unless constants.const_defined?(name, false)

        constants.const_get(name, false)
      end

      def function(handle, name, argument_types)
        Fiddle::Function.new(
          handle[name],
          argument_types,
          Fiddle::TYPE_INT,
          need_gvl: true
        )
      end

      def optional_function(handle, name, argument_types)
        function(handle, name, argument_types)
      rescue Fiddle::DLError
        nil
      end

      def call_openat(directory_fd, name, flags, mode: nil)
        if mode
          call(
            @openat_with_mode,
            directory_fd,
            name,
            flags,
            Integer(mode),
            operation: "openat"
          )
        else
          call(@openat, directory_fd, name, flags, operation: "openat")
        end
      end

      def call(function, *arguments, operation:)
        Fiddle.last_error = 0
        result = function.call(*arguments)
        return result unless result == -1

        raise SystemCallError.new(operation, Fiddle.last_error)
      end

      def directory_from_fd(fd)
        mark_close_on_exec(fd)
        Dir.for_fd(fd)
      end

      def file_from_fd(fd)
        mark_close_on_exec(fd)
        File.for_fd(fd)
      end

      def mark_close_on_exec(fd)
        IO.for_fd(fd, autoclose: false).close_on_exec = true
      end

      def close_fd(fd)
        IO.for_fd(fd).close if fd && fd >= 0
      rescue SystemCallError, IOError, ArgumentError
        nil
      end

      def component!(name, allow_dot: false)
        valid = name.is_a?(String) &&
          !name.empty? &&
          !name.include?(File::SEPARATOR) &&
          !name.include?("\0") &&
          name != ".." &&
          (allow_dot || name != ".")
        raise ArgumentError, "invalid managed component" unless valid
      end
    end
  end
end
