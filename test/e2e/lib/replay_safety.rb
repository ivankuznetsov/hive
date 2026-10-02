require "hive/managed_directory"

module Hive
  module E2E
    # Holds the runs-tree generation and selected repro script by descriptor.
    # Public pathnames are consulted only while selecting and at the final
    # binding fence; the only launch path this object returns is an identity-
    # checked alias for the held script descriptor.
    class ReplaySafety
      DEFAULT_DESCRIPTOR_ALIAS_ROOTS = [ "/proc/self/fd", "/dev/fd" ].freeze

      class Error < StandardError
        attr_reader :kind, :reason
        alias error_kind kind

        def initialize(kind:, reason:)
          @kind = kind.freeze
          @reason = reason.freeze
          super(message_for(kind, reason))
        end

        private

        def message_for(kind, reason)
          case kind
          when "missing_repro"
            "replay artifact is missing (#{reason})"
          when "unusable_repro"
            "replay artifact is unusable (#{reason})"
          else
            "replay preflight failed (#{reason})"
          end
        end
      end

      # Lifetime owner returned only after the public-binding fence and alias
      # verification both pass. Callers keep it alive through launch and close
      # it after the supervised child reaches a terminal state.
      class Custody
        attr_reader :canonical_root, :root_identity, :script_identity,
                    :descriptor_alias

        def initialize(handles:, canonical_root:, root_identity:,
                       script_identity:, descriptor_alias:)
          @handles = handles
          @canonical_root = canonical_root.freeze
          @root_identity = root_identity.freeze
          @script_identity = script_identity.freeze
          @descriptor_alias = descriptor_alias.freeze
          @script = handles.last
          @closed = false
        end

        def script_fd
          raise IOError, "replay custody is closed" if closed?

          @script.fileno
        end

        def closed?
          @closed
        end

        def close
          return if closed?

          @closed = true
          @handles.reverse_each do |handle|
            handle.close
          rescue IOError, SystemCallError
            nil
          end
          @handles.clear
          nil
        end
      end

      def initialize(runs_root:, native: nil,
                     native_factory: Hive::ManagedDirectory.method(:build_native_at_adapter),
                     filesystem: File,
                     descriptor_alias_roots: DEFAULT_DESCRIPTOR_ALIAS_ROOTS,
                     on_event: nil)
        @runs_root = File.expand_path(runs_root).freeze
        @filesystem = filesystem
        @descriptor_alias_roots = Array(descriptor_alias_roots).map do |root|
          File.expand_path(root).freeze
        end.freeze
        @on_event = on_event
        @native = native || native_factory.call
      rescue Hive::ManagedDirectory::NativeAdapterUnavailable
        failure!("preflight", "descriptor_exec_unavailable")
      end

      def select(run_id:, scenario:)
        handles = []
        root, root_stat, canonical_root = pin_root
        handles << root
        emit(:root_pinned)

        components = [
          [ run_id, "run" ],
          [ "scenarios", "scenarios" ],
          [ scenario, "scenario" ]
        ]
        held_entries = []
        parent = root
        components.each do |name, label|
          directory, stat = open_initial_directory(parent, name, label)
          handles << directory
          held_entries << [ name, label, identity(stat) ]
          parent = directory
        end

        script, script_stat = open_initial_script(parent)
        handles << script
        script_identity = identity(script_stat)
        emit(:artifact_pinned)

        final_binding_fence!(
          root_identity: identity(root_stat),
          entries: held_entries,
          script_identity: script_identity
        )
        emit(:final_fence_passed)
        descriptor_alias = verified_descriptor_alias(script, script_identity)

        custody = Custody.new(
          handles: handles,
          canonical_root: canonical_root,
          root_identity: identity(root_stat),
          script_identity: script_identity,
          descriptor_alias: descriptor_alias
        )
        handles = nil
        custody
      ensure
        close_handles(handles) if handles
      end

      private

      def pin_root
        before = initial_root_stat
        root = @native.open_absolute_directory(@runs_root)
        opened = directory_stat(root)
        unless opened.directory? && identity(before) == identity(opened)
          failure!("unusable_repro", "runs_root_changed")
        end

        canonical_root = capture_canonical_root(identity(opened))
        complete = true
        [ root, opened, canonical_root ]
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Errno::ENOENT
        failure!("missing_repro", "runs_root_missing")
      rescue Errno::ELOOP
        failure!("unusable_repro", "runs_root_symlink")
      rescue SystemCallError, IOError, ArgumentError, TypeError
        classify_initial_root_failure(before)
      ensure
        root&.close unless complete
      end

      def initial_root_stat
        stat = @filesystem.lstat(@runs_root)
        if stat.symlink?
          failure!("unusable_repro", "runs_root_symlink")
        elsif !stat.directory?
          failure!("unusable_repro", "runs_root_unusable")
        end
        stat
      rescue Errno::ENOENT, Errno::ENOTDIR
        failure!("missing_repro", "runs_root_missing")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "runs_root_unusable")
      end

      def classify_initial_root_failure(before)
        current = @filesystem.lstat(@runs_root)
        if current.symlink?
          failure!("unusable_repro", "runs_root_symlink")
        elsif !current.directory?
          failure!("unusable_repro", "runs_root_unusable")
        elsif before && identity(before) != identity(current)
          failure!("unusable_repro", "runs_root_changed")
        else
          failure!("unusable_repro", "runs_root_unusable")
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        failure!("missing_repro", "runs_root_missing")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "runs_root_unusable")
      end

      def capture_canonical_root(root_identity)
        verify_public_root_identity!(root_identity)
        canonical = @filesystem.realpath(@runs_root)
        canonical_stat = @filesystem.stat(canonical)
        unless canonical_stat.directory? && identity(canonical_stat) == root_identity
          failure!("unusable_repro", "runs_root_changed")
        end
        verify_public_root_identity!(root_identity)
        canonical
      rescue Errno::ENOENT, Errno::ENOTDIR
        failure!("unusable_repro", "runs_root_missing")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "runs_root_changed")
      end

      def verify_public_root_identity!(expected)
        current = @filesystem.lstat(@runs_root)
        if current.symlink?
          failure!("unusable_repro", "runs_root_symlink")
        elsif !current.directory? || identity(current) != expected
          failure!("unusable_repro", "runs_root_changed")
        end
        nil
      rescue Errno::ENOENT, Errno::ENOTDIR
        failure!("unusable_repro", "runs_root_missing")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      end

      def open_initial_directory(parent, name, label)
        directory = @native.open_directory(parent, name)
        stat = directory_stat(directory)
        failure!("unusable_repro", "#{label}_unusable") unless stat.directory?
        complete = true
        [ directory, stat ]
      rescue Errno::ENOENT
        failure!("missing_repro", "#{label}_missing")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "#{label}_unusable")
      ensure
        directory&.close unless complete
      end

      def open_initial_script(parent)
        script = @native.open_file(
          parent,
          "repro.sh",
          File::RDONLY | File::NONBLOCK
        )
        stat = script.stat
        failure!("unusable_repro", "repro_unusable") unless usable_script?(stat)
        complete = true
        [ script, stat ]
      rescue Errno::ENOENT
        failure!("missing_repro", "repro_missing")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "repro_unusable")
      ensure
        script&.close unless complete
      end

      def final_binding_fence!(root_identity:, entries:, script_identity:)
        opened = []
        root = open_root_for_fence(root_identity)
        opened << root
        parent = root

        entries.each do |name, label, expected|
          directory = open_directory_for_fence(parent, name, label, expected)
          opened << directory
          parent = directory
        end

        script = open_script_for_fence(parent, script_identity)
        opened << script
        nil
      ensure
        close_handles(opened)
      end

      def open_root_for_fence(expected)
        verify_public_root_identity!(expected)
        root = @native.open_absolute_directory(@runs_root)
        stat = directory_stat(root)
        failure!("unusable_repro", "runs_root_changed") unless
          stat.directory? && identity(stat) == expected
        complete = true
        root
      rescue Errno::ENOENT, Errno::ENOTDIR
        root_fence_failure!
      rescue Errno::ELOOP
        failure!("unusable_repro", "runs_root_symlink")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        root_fence_failure!
      ensure
        root&.close unless complete
      end

      def root_fence_failure!
        current = @filesystem.lstat(@runs_root)
        if current.symlink?
          failure!("unusable_repro", "runs_root_symlink")
        elsif current.directory?
          failure!("unusable_repro", "runs_root_changed")
        else
          failure!("unusable_repro", "runs_root_changed")
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        failure!("unusable_repro", "runs_root_missing")
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "runs_root_changed")
      end

      def open_directory_for_fence(parent, name, label, expected)
        directory = @native.open_directory(parent, name)
        stat = directory_stat(directory)
        failure!("unusable_repro", "#{label}_changed") unless
          stat.directory? && identity(stat) == expected
        complete = true
        directory
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "#{label}_changed")
      ensure
        directory&.close unless complete
      end

      def open_script_for_fence(parent, expected)
        script = @native.open_file(
          parent,
          "repro.sh",
          File::RDONLY | File::NONBLOCK
        )
        stat = script.stat
        failure!("unusable_repro", "repro_changed") unless identity(stat) == expected
        failure!("unusable_repro", "repro_unusable") unless usable_script?(stat)
        complete = true
        script
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unreadable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("unusable_repro", "repro_changed")
      ensure
        script&.close unless complete
      end

      def verified_descriptor_alias(script, expected)
        @descriptor_alias_roots.each do |root|
          candidate = File.join(root, script.fileno.to_s)
          begin
            stat = @filesystem.stat(candidate)
            return candidate if identity(stat) == expected
          rescue SystemCallError, IOError, ArgumentError, TypeError
            next
          end
        end
        failure!("preflight", "descriptor_exec_unavailable")
      end

      def usable_script?(stat)
        stat.file? && (stat.mode & 0o111).positive?
      end

      def identity(stat)
        [ stat.dev, stat.ino, stat.mode & 0o170000 ].freeze
      end

      def directory_stat(directory)
        IO.for_fd(directory.fileno, autoclose: false).stat
      end

      def emit(event)
        @on_event&.call(event)
      end

      def close_handles(handles)
        handles&.reverse_each do |handle|
          handle.close
        rescue IOError, SystemCallError
          nil
        end
      end

      def failure!(kind, reason)
        raise Error.new(kind: kind, reason: reason)
      end
    end
  end
end
