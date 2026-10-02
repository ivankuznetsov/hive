require "digest"
require "fileutils"
require "hive/managed_directory"
require_relative "paths"

module Hive
  module E2E
    # Holds the runs-tree generation and selected repro script by descriptor.
    # Public pathnames are consulted only while selecting and at the final
    # binding fence; the only launch path this object returns is an identity-
    # checked alias for the held script descriptor.
    class ReplaySafety
      DEFAULT_DESCRIPTOR_ALIAS_ROOTS = [ "/proc/self/fd", "/dev/fd" ].freeze
      SHARD_COUNT = 256
      CONTROL_DIRECTORY_MODE = 0o700
      SHARD_MODE = 0o600

      DEFAULT_SHARD_SELECTOR = lambda do |tuples|
        tuples.map { |tuple| Digest::SHA256.digest(tuple).getbyte(0) }
      end

      class LockOperations
        def mkdir_p(path, mode:)
          FileUtils.mkdir_p(path, mode: mode)
        end

        def lstat(path)
          File.lstat(path)
        end

        def stat(handle)
          IO.for_fd(handle.fileno, autoclose: false).stat
        end

        def flock(handle, operation, _shard_index)
          handle.flock(operation)
        end

        def euid
          Process.euid
        end
      end
      private_constant :LockOperations

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
                    :descriptor_alias, :executable_descriptor_alias,
                    :native_launch_alias

        def initialize(handles:, admission:, script:, canonical_root:,
                       root_identity:, script_identity:, descriptor_alias:,
                       executable_script: nil, executable_descriptor_alias: nil,
                       native_launch_alias: nil)
          @handles = handles
          @admission = admission
          @canonical_root = canonical_root.freeze
          @root_identity = root_identity.freeze
          @script_identity = script_identity.freeze
          @descriptor_alias = descriptor_alias.freeze
          @script = script
          @executable_script = executable_script
          @executable_descriptor_alias = executable_descriptor_alias&.freeze
          @native_launch_alias = native_launch_alias&.freeze
          @closed = false
        end

        def script_fd
          raise IOError, "replay custody is closed" if closed?

          @script.fileno
        end

        def executable_script_fd
          raise IOError, "replay custody is closed" if closed?

          @executable_script&.fileno
        end

        def closed?
          @closed
        end

        def close
          return if closed?

          @closed = true
          begin
            File.unlink(@native_launch_alias) if @native_launch_alias
          rescue SystemCallError
            nil
          end
          @handles.reverse_each do |handle|
            handle.close
          rescue IOError, SystemCallError
            nil
          end
          @handles.clear
          @admission.close
          nil
        end
      end

      class Admission
        def initialize(control:, shards:, lock_operations:)
          @control = control
          @shards = shards
          @lock_operations = lock_operations
          @closed = false
        end

        def close
          return if @closed

          @closed = true
          @shards.reverse_each do |index, handle|
            begin
              @lock_operations.flock(handle, File::LOCK_UN, index)
            rescue NotImplementedError, StandardError
              nil
            end
            begin
              handle.close
            rescue StandardError
              nil
            end
          end
          @shards.clear
          @control.close
        rescue StandardError
          nil
        end
      end
      private_constant :Admission

      def initialize(runs_root:, native: nil,
                     native_factory: Hive::ManagedDirectory.method(:build_native_at_adapter),
                     filesystem: File,
                     control_root: Paths.replay_control_dir,
                     shard_selector: DEFAULT_SHARD_SELECTOR,
                     lock_operations: LockOperations.new,
                     descriptor_alias_roots: DEFAULT_DESCRIPTOR_ALIAS_ROOTS,
                     platform: RUBY_PLATFORM,
                     on_event: nil)
        @runs_root = File.expand_path(runs_root).freeze
        @filesystem = filesystem
        @control_root = File.expand_path(control_root).freeze
        @shard_selector = shard_selector
        @lock_operations = lock_operations
        @descriptor_alias_roots = Array(descriptor_alias_roots).map do |root|
          File.expand_path(root).freeze
        end.freeze
        @platform = platform.to_s.freeze
        @on_event = on_event
        @native = native || native_factory.call
      rescue Hive::ManagedDirectory::NativeAdapterUnavailable
        failure!("preflight", "descriptor_exec_unavailable")
      end

      def select(run_id:, scenario:)
        handles = []
        admission = nil
        native_launch_alias = nil
        root, root_stat, canonical_root = pin_root
        handles << root
        emit(:root_pinned)

        root_identity = identity(root_stat)
        admission = acquire_admission(
          root_identity: root_identity,
          canonical_root: canonical_root,
          run_id: run_id,
          scenario: scenario
        )
        emit(:admission_acquired)

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
        executable_script = open_executable_script(parent, script_identity)
        handles << executable_script if executable_script
        executable_descriptor_alias = if executable_script
                                        verified_executable_descriptor_alias(
                                          executable_script
                                        )
        end
        emit(:artifact_pinned)

        final_binding_fence!(
          root_identity: identity(root_stat),
          entries: held_entries,
          script_identity: script_identity
        )
        native_launch_alias = create_native_launch_alias(
          script: script,
          run_id: run_id,
          scenario: scenario,
          canonical_root: canonical_root,
          root_identity: root_identity,
          script_identity: script_identity
        )
        emit(:final_fence_passed)
        descriptor_alias = verified_descriptor_alias(script, script_identity)

        custody = Custody.new(
          handles: handles,
          admission: admission,
          script: script,
          canonical_root: canonical_root,
          root_identity: root_identity,
          script_identity: script_identity,
          descriptor_alias: descriptor_alias,
          executable_script: executable_script,
          executable_descriptor_alias: executable_descriptor_alias,
          native_launch_alias: native_launch_alias
        )
        handles = nil
        admission = nil
        native_launch_alias = nil
        custody
      ensure
        cleanup_native_launch_alias(native_launch_alias)
        close_handles(handles) if handles
        admission&.close
      end

      private

      def acquire_admission(root_identity:, canonical_root:, run_id:, scenario:)
        control = prepare_control_directory
        shards = []
        shard_indices(
          root_identity: root_identity,
          canonical_root: canonical_root,
          run_id: run_id,
          scenario: scenario
        ).each do |index|
          shard = open_lock_shard(control, index)
          shards << [ index, shard ]
          acquired = @lock_operations.flock(
            shard,
            File::LOCK_EX | File::LOCK_NB,
            index
          )
          failure!("replay_busy", "replay_busy") unless acquired

          validate_shard_binding!(shard, index)
        end
        validate_control_binding!(control)

        admission = Admission.new(
          control: control,
          shards: shards,
          lock_operations: @lock_operations
        )
        control = nil
        shards = nil
        admission
      rescue Error
        raise
      rescue NotImplementedError, StandardError
        failure!("preflight", "replay_lock_unavailable")
      ensure
        release_lock_shards(shards) if shards
        close_handle(control)
      end

      def prepare_control_directory
        @lock_operations.mkdir_p(
          @control_root,
          mode: CONTROL_DIRECTORY_MODE
        )
        before = @lock_operations.lstat(@control_root)
        control = @native.open_absolute_directory(@control_root)
        emit(:control_directory_opened)
        opened = @lock_operations.stat(control)
        after = @lock_operations.lstat(@control_root)
        unless usable_control_directory?(before) &&
               usable_control_directory?(opened) &&
               usable_control_directory?(after) &&
               same_binding?(before, opened) &&
               same_binding?(opened, after)
          failure!("preflight", "replay_lock_unavailable")
        end
        complete = true
        control
      rescue Error
        raise
      rescue NotImplementedError, StandardError
        failure!("preflight", "replay_lock_unavailable")
      ensure
        close_handle(control) unless complete
      end

      def shard_indices(root_identity:, canonical_root:, run_id:, scenario:)
        tuples = [
          length_prefixed_tuple(
            "configured-root-v1", @runs_root, run_id, scenario
          ),
          length_prefixed_tuple(
            "canonical-root-v1", canonical_root, run_id, scenario
          ),
          length_prefixed_tuple(
            "root-identity-v1",
            root_identity.fetch(0),
            root_identity.fetch(1),
            run_id,
            scenario
          )
        ].freeze
        indices = Array(@shard_selector.call(tuples)).map { |index| Integer(index) }
        unless indices.any? && indices.all? { |index| index.between?(0, SHARD_COUNT - 1) }
          failure!("preflight", "replay_lock_unavailable")
        end
        indices.uniq.sort.freeze
      rescue Error
        raise
      rescue StandardError
        failure!("preflight", "replay_lock_unavailable")
      end

      def length_prefixed_tuple(*fields)
        fields.map do |field|
          value = field.to_s.b
          [ value.bytesize ].pack("N") + value
        end.join.b.freeze
      end

      def open_lock_shard(control, index)
        name = shard_name(index)
        begin
          shard = @native.open_file(
            control,
            name,
            File::RDWR | File::CREAT | File::EXCL | File::NONBLOCK,
            mode: SHARD_MODE
          )
        rescue Errno::EEXIST
          shard = @native.open_file(
            control,
            name,
            File::RDWR | File::NONBLOCK
          )
        end
        emit([ :lock_shard_opened, index ])
        validate_shard_binding!(shard, index)
        complete = true
        shard
      rescue Error
        raise
      rescue NotImplementedError, StandardError
        failure!("preflight", "replay_lock_unavailable")
      ensure
        close_handle(shard) unless complete
      end

      def validate_control_binding!(control)
        opened = @lock_operations.stat(control)
        bound = @lock_operations.lstat(@control_root)
        return if usable_control_directory?(opened) &&
          usable_control_directory?(bound) &&
          same_binding?(opened, bound)

        failure!("preflight", "replay_lock_unavailable")
      end

      def validate_shard_binding!(shard, index)
        opened = @lock_operations.stat(shard)
        bound = @lock_operations.lstat(File.join(@control_root, shard_name(index)))
        return if usable_lock_shard?(opened) && usable_lock_shard?(bound) &&
          same_binding?(opened, bound)

        failure!("preflight", "replay_lock_unavailable")
      end

      def usable_control_directory?(stat)
        stat.directory? && !stat.symlink? &&
          stat.uid == @lock_operations.euid &&
          (stat.mode & 0o7777) == CONTROL_DIRECTORY_MODE &&
          usable_control_link_count?(stat.nlink)
      end

      def usable_control_link_count?(count)
        return count.between?(1, SHARD_COUNT + 2) if @platform.include?("darwin")

        [ 1, 2 ].include?(count)
      end

      def usable_lock_shard?(stat)
        stat.file? && !stat.symlink? &&
          stat.uid == @lock_operations.euid &&
          (stat.mode & 0o7777) == SHARD_MODE &&
          stat.nlink == 1 && stat.size.zero?
      end

      def same_binding?(left, right)
        left.dev == right.dev && left.ino == right.ino
      end

      def shard_name(index)
        format("replay-%02x.lock", index)
      end

      def release_lock_shards(shards)
        shards.reverse_each do |index, shard|
          begin
            @lock_operations.flock(shard, File::LOCK_UN, index)
          rescue NotImplementedError, StandardError
            nil
          end
          close_handle(shard)
        end
        shards.clear
      end

      def close_handle(handle)
        handle&.close
      rescue SystemCallError, IOError
        nil
      end

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

      def open_executable_script(parent, expected)
        return unless @platform.include?("darwin")

        script = @native.open_executable(parent, "repro.sh")
        failure!("unusable_repro", "repro_changed") unless
          identity(script.stat) == expected
        complete = true
        script
      rescue Errno::EACCES
        failure!("unusable_repro", "repro_unusable")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("preflight", "descriptor_exec_unavailable")
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
            stat = descriptor_alias_stat(candidate)
            return candidate if identity(stat) == expected
          rescue SystemCallError, IOError, ArgumentError, TypeError
            next
          end
        end
        failure!("preflight", "descriptor_exec_unavailable")
      end

      def descriptor_alias_stat(candidate)
        return @filesystem.stat(candidate) unless @platform.include?("darwin")

        @filesystem.open(candidate, File::RDONLY, &:stat)
      end

      def verified_executable_descriptor_alias(script)
        @descriptor_alias_roots.each do |root|
          next unless root == "/dev/fd"

          candidate = File.join(root, script.fileno.to_s)
          begin
            @filesystem.lstat(candidate)
            return candidate
          rescue SystemCallError, IOError, ArgumentError, TypeError
            next
          end
        end
        failure!("preflight", "descriptor_exec_unavailable")
      end

      def create_native_launch_alias(script:, run_id:, scenario:, canonical_root:,
                                     root_identity:, script_identity:)
        return unless @platform.include?("darwin") &&
          script.pread(4096, 0).include?("\0")

        key = length_prefixed_tuple(
          "native-launch-v1", @runs_root, canonical_root,
          root_identity.fetch(0), root_identity.fetch(1), run_id, scenario
        )
        candidate = File.join(
          @control_root,
          "launch-#{Digest::SHA256.hexdigest(key)}"
        )
        cleanup_native_launch_alias(candidate)
        source = File.join(
          @runs_root, run_id, "scenarios", scenario, "repro.sh"
        )
        File.link(source, candidate)
        linked = @filesystem.lstat(candidate)
        failure!("unusable_repro", "repro_changed") unless
          linked.file? && identity(linked) == script_identity
        complete = true
        candidate
      rescue Errno::ENOENT, Errno::ENOTDIR
        failure!("unusable_repro", "repro_changed")
      rescue Error
        raise
      rescue SystemCallError, IOError, ArgumentError, TypeError
        failure!("preflight", "descriptor_exec_unavailable")
      ensure
        cleanup_native_launch_alias(candidate) unless complete
      end

      def cleanup_native_launch_alias(path)
        File.unlink(path) if path
      rescue Errno::ENOENT
        nil
      rescue SystemCallError
        nil
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
