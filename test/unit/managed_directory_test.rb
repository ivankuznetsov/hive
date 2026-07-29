require "test_helper"
require "digest"
require "hive/managed_directory"

class ManagedDirectoryTest < Minitest::Test
  include HiveTestHelper

  def test_prepares_private_directories_and_reads_atomic_writes
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state", "evidence")
      directory = Hive::ManagedDirectory.new(
        root: root,
        anchor: anchor,
        label: "test state"
      )

      directory.prepare!
      directory.ensure_directory("nested/records")
      assert_equal(
        File.join(root, "nested", "records", "one.json"),
        directory.atomic_write("nested/records/one.json", "one", mode: 0o600)
      )
      assert_equal "one", directory.read("nested/records/one.json", max_bytes: 3)
      assert_nil directory.read("nested/records/missing.json", max_bytes: 3, missing: true)
      assert_equal [ "one.json" ],
                   directory.each_child("nested/records").to_a
      assert_equal 0o700, File.stat(File.join(root, "nested")).mode & 0o777
      assert_equal 0o600,
                   File.stat(File.join(root, "nested", "records", "one.json")).mode & 0o777

      locked = false
      directory.with_lock("state.lock") { locked = true }
      assert locked
      assert_equal 0o600, File.stat(File.join(root, "state.lock")).mode & 0o777
    end
  end

  def test_accepts_the_filesystem_root_as_the_nearest_existing_anchor
    root = File.join(
      File::SEPARATOR,
      "hive-managed-directory-#{Process.pid}-#{SecureRandom.hex(6)}"
    )
    refute_path_exists root

    directory = Hive::ManagedDirectory.new(
      root: root,
      label: "test state"
    )

    assert_equal root, directory.root
  end

  def test_rejects_unsafe_relative_paths_and_symlinked_components
    with_tmp_dir do |anchor|
      outside = File.join(anchor, "outside")
      FileUtils.mkdir_p(outside)
      root = File.join(anchor, "state")
      directory = Hive::ManagedDirectory.new(
        root: root,
        anchor: anchor,
        label: "test state"
      )
      directory.prepare!

      %w[../outside /absolute nested/../outside].each do |relative|
        assert_raises(Hive::ConfigError) do
          directory.atomic_write(relative, "unsafe")
        end
      end

      File.symlink(outside, File.join(root, "linked"))
      assert_raises(Hive::ConfigError) do
        directory.ensure_directory("linked/child")
      end
      assert_raises(Hive::ConfigError) do
        directory.atomic_write("linked/file", "unsafe")
      end

      FileUtils.mkdir_p(File.join(root, "nested"))
      FileUtils.mkdir_p(File.join(outside, "deep"))
      File.write(File.join(outside, "deep", "escaped"), "outside")
      File.symlink(outside, File.join(root, "nested", "linked"))
      assert_raises(Hive::ConfigError) do
        directory.read("nested/linked/deep/escaped", max_bytes: 16)
      end
      assert_raises(Hive::ConfigError) do
        directory.each_child("nested/linked/deep").to_a
      end

      File.symlink(File.join(outside, "record"), File.join(root, "record"))
      assert_raises(Hive::ConfigError) do
        directory.read("record", max_bytes: 16)
      end

      File.symlink(File.join(outside, "lock"), File.join(root, "unsafe.lock"))
      assert_raises(Hive::ConfigError) do
        directory.with_lock("unsafe.lock") { flunk "unsafe lock yielded" }
      end

      linked_lock = File.join(outside, "linked-lock")
      File.write(linked_lock, "")
      File.chmod(0o644, linked_lock)
      File.link(linked_lock, File.join(root, "linked.lock"))
      assert_raises(Hive::ConfigError) do
        directory.with_lock("linked.lock") { flunk "linked lock yielded" }
      end
      assert_equal 0o644, File.stat(linked_lock).mode & 0o777
    end
  end

  def test_rejects_oversized_and_non_regular_files
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "test state")
      File.write(File.join(root, "large"), "four")
      FileUtils.mkdir_p(File.join(root, "folder"))

      assert_raises(Hive::ConfigError) do
        directory.read("large", max_bytes: 3)
      end
      assert_raises(Hive::ConfigError) do
        directory.read("folder", max_bytes: 3)
      end
      assert_raises(Hive::ConfigError) do
        directory.atomic_write("folder", "unsafe")
      end
    end
  end

  def test_expected_digest_fences_replacement_and_bounded_existing_reads
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      )
      path = File.join(root, "record")
      File.write(path, "before")
      digest = Digest::SHA256.hexdigest("before")

      directory.atomic_write(
        "record",
        "after",
        expected_digest: digest,
        max_existing_bytes: 6
      )
      assert_equal "after", File.binread(path)

      error = assert_raises(Hive::ConfigError) do
        directory.atomic_write(
          "record",
          "wrong",
          expected_digest: digest,
          max_existing_bytes: 6
        )
      end
      assert_equal "test state managed directory is unsafe", error.message
      assert_equal "after", File.binread(path)

      oversized = Digest::SHA256.hexdigest("after")
      assert_raises(Hive::ConfigError) do
        directory.atomic_write(
          "record",
          "wrong",
          expected_digest: oversized,
          max_existing_bytes: 4
        )
      end
      assert_equal "after", File.binread(path)
    end
  end

  def test_expected_digest_detects_replacement_race_before_atomic_rename
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      )
      target = File.join(root, "record")
      File.write(target, "before")
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_file)

      with_replaced_singleton_method(
        native,
        :open_file,
        lambda do |parent, name, flags, mode: nil|
          result = original_open.call(parent, name, flags, mode: mode)
          if name.start_with?(".record.tmp.")
            File.open(
              target,
              File::WRONLY | File::TRUNC
            ) { |file| file.write("raced!") }
          end
          result
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.atomic_write(
            "record",
            "after",
            expected_digest: Digest::SHA256.hexdigest("before"),
            max_existing_bytes: 6
          )
        end
      end

      assert_equal "raced!", File.binread(target)
      names = Dir.children(root)
      refute names.any? { |name| name.start_with?(".record.tmp.") },
             names.inspect
    end
  end

  def test_atomic_write_does_not_follow_a_substituted_parent
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      outside = File.join(anchor, "outside")
      FileUtils.mkdir_p(outside)
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      directory.ensure_directory("nested")
      parent = File.join(root, "nested")
      parked = File.join(root, "nested.parked")
      target = File.join(parent, "record")
      sentinel = File.join(outside, "record")
      File.write(sentinel, "external sentinel")
      sentinel_before = file_identity_and_digest(sentinel)
      original_rename = File.method(:rename)
      native = directory.instance_variable_get(:@native)
      original_renameat = native.method(:renameat)
      substituted = false

      begin
        with_replaced_singleton_method(
          native,
          :renameat,
          lambda do |source_parent, source_name, target_parent, target_name|
            if target_name == File.basename(target)
              original_rename.call(parent, parked)
              File.symlink(outside, parent)
              substituted = true
            end
            original_renameat.call(
              source_parent,
              source_name,
              target_parent,
              target_name
            )
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.atomic_write("nested/record", "managed content")
          end
        end

        assert substituted
        assert_equal sentinel_before, file_identity_and_digest(sentinel)
      ensure
        File.unlink(parent) if File.symlink?(parent)
        original_rename.call(parked, parent) if File.directory?(parked)
      end
    end
  end

  def test_temporary_creation_and_cleanup_stay_in_the_opened_parent
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      outside = File.join(anchor, "outside")
      FileUtils.mkdir_p(outside)
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      directory.ensure_directory("nested")
      parent = File.join(root, "nested")
      parked = File.join(root, "nested.parked")
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_file)
      original_rename = File.method(:rename)
      identity_reader = method(:file_identity_and_digest)
      external_temporary = {}

      begin
        with_replaced_singleton_method(
          native,
          :open_file,
          lambda do |descriptor, name, flags, mode: nil|
            if name.start_with?(".record.tmp.") && external_temporary.empty?
              original_rename.call(parent, parked)
              File.symlink(outside, parent)
              external_temporary[:path] = File.join(outside, name)
              File.write(external_temporary.fetch(:path), "external sentinel")
              external_temporary[:identity] =
                identity_reader.call(external_temporary.fetch(:path))
            end
            original_open.call(descriptor, name, flags, mode: mode)
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.atomic_write("nested/record", "managed content")
          end
        end

        refute_empty external_temporary
        assert_equal external_temporary.fetch(:identity),
                     file_identity_and_digest(external_temporary.fetch(:path))
      ensure
        File.unlink(parent) if File.symlink?(parent)
        original_rename.call(parked, parent) if File.directory?(parked)
      end

      refute Dir.children(parent).any? { |name| name.start_with?(".record.tmp.") }
    end
  end

  def test_read_and_lock_stay_in_the_opened_parent
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      outside = File.join(anchor, "outside")
      FileUtils.mkdir_p(outside)
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      directory.ensure_directory("nested")
      parent = File.join(root, "nested")
      parked = File.join(root, "nested.parked")
      managed_record = File.join(parent, "record")
      external_record = File.join(outside, "record")
      File.write(managed_record, "managed content")
      File.write(external_record, "external sentinel")
      sentinel_before = file_identity_and_digest(external_record)
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_file)
      original_rename = File.method(:rename)

      begin
        substituted = false
        with_replaced_singleton_method(
          native,
          :open_file,
          lambda do |descriptor, name, flags, mode: nil|
            if name == "record" && !substituted
              original_rename.call(parent, parked)
              File.symlink(outside, parent)
              substituted = true
            end
            original_open.call(descriptor, name, flags, mode: mode)
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.read("nested/record", max_bytes: 32)
          end
        end
        assert substituted
        assert_equal sentinel_before, file_identity_and_digest(external_record)
      ensure
        File.unlink(parent) if File.symlink?(parent)
        original_rename.call(parked, parent) if File.directory?(parked)
      end

      external_lock = File.join(outside, "state.lock")
      File.write(external_lock, "external lock sentinel")
      lock_before = file_identity_and_digest(external_lock)
      yielded = false
      begin
        substituted = false
        with_replaced_singleton_method(
          native,
          :open_file,
          lambda do |descriptor, name, flags, mode: nil|
            if name == "state.lock" && !substituted
              original_rename.call(parent, parked)
              File.symlink(outside, parent)
              substituted = true
            end
            original_open.call(descriptor, name, flags, mode: mode)
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.with_lock("nested/state.lock") { yielded = true }
          end
        end
        assert substituted
        refute yielded
        assert_equal lock_before, file_identity_and_digest(external_lock)
      ensure
        File.unlink(parent) if File.symlink?(parent)
        original_rename.call(parked, parent) if File.directory?(parked)
      end
    end
  end

  def test_nested_operations_reuse_the_lock_descriptor_session
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "test state")
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_absolute_directory)
      anchor_opens = 0

      with_replaced_singleton_method(
        native,
        :open_absolute_directory,
        lambda do |path|
          anchor_opens += 1
          original_open.call(path)
        end
      ) do
        directory.with_lock("state.lock") do
          directory.atomic_write("record", "nested")
          assert_equal "nested", directory.read("record", max_bytes: 6)
        end
      end

      assert_equal 1, anchor_opens
      assert_nil Thread.current[:hive_managed_directory_sessions]
    end
  end

  def test_missing_root_does_not_leak_the_session_registry
    with_tmp_dir do |anchor|
      directory = Hive::ManagedDirectory.new(
        root: File.join(anchor, "missing"),
        anchor: anchor,
        label: "test state"
      )

      assert_nil directory.read("record", max_bytes: 1, missing: true)
      assert_nil Thread.current[:hive_managed_directory_sessions]
    end
  end

  def test_unlink_is_digest_fenced_no_follow_and_missing_aware
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      )
      target = File.join(root, "record")
      File.write(target, "retire")
      digest = Digest::SHA256.hexdigest("retire")

      assert_raises(Hive::ConfigError) do
        directory.unlink(
          "record",
          expected_digest: Digest::SHA256.hexdigest("other"),
          max_bytes: 6
        )
      end
      assert File.file?(target)
      assert directory.unlink(
        "record", expected_digest: digest, max_bytes: 6
      )
      refute File.exist?(target)
      refute directory.unlink("record", missing: true)

      outside = File.join(root, "outside")
      File.write(outside, "outside")
      File.symlink(outside, target)
      assert_raises(Hive::ConfigError) do
        directory.unlink("record")
      end
      assert_equal "outside", File.binread(outside)

      File.unlink(target)
      FileUtils.mkdir_p(target)
      assert_raises(Hive::ConfigError) do
        directory.unlink("record")
      end
    end
  end

  def test_unlink_does_not_follow_a_substituted_parent
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      outside = File.join(anchor, "outside")
      FileUtils.mkdir_p(outside)
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      directory.ensure_directory("nested")
      parent = File.join(root, "nested")
      parked = File.join(root, "nested.parked")
      target = File.join(parent, "record")
      sentinel = File.join(outside, "record")
      File.write(target, "managed content")
      File.write(sentinel, "external sentinel")
      sentinel_before = file_identity_and_digest(sentinel)
      original_unlink = File.method(:unlink)
      original_rename = File.method(:rename)
      native = directory.instance_variable_get(:@native)
      original_unlinkat = native.method(:unlinkat)
      substituted = false

      begin
        with_replaced_singleton_method(
          native,
          :unlinkat,
          lambda do |target_parent, name|
            if name == File.basename(target)
              original_rename.call(parent, parked)
              File.symlink(outside, parent)
              substituted = true
            end
            original_unlinkat.call(target_parent, name)
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.unlink("nested/record")
          end
        end

        assert substituted
        assert_equal sentinel_before, file_identity_and_digest(sentinel)
      ensure
        original_unlink.call(parent) if File.symlink?(parent)
        original_rename.call(parked, parent) if File.directory?(parked)
      end
    end
  end

  def test_successful_unlink_fsyncs_its_verified_parent
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      )
      File.write(File.join(root, "record"), "retire")
      calls = []
      native = directory.instance_variable_get(:@native)
      native.define_singleton_method(:fsync_directory) do |parent|
        stat = IO.for_fd(parent.fileno, autoclose: false).stat
        calls << [ stat.dev, stat.ino ]
      end

      assert directory.unlink("record")
      assert_equal 1, calls.size
      root_stat = File.stat(root)
      assert_equal [ root_stat.dev, root_stat.ino ], calls.first
    end
  end

  def test_anchor_must_contain_the_root_without_symlinks
    with_tmp_dir do |anchor|
      outside = File.join(anchor, "outside")
      FileUtils.mkdir_p(outside)
      link = File.join(anchor, "link")
      File.symlink(outside, link)

      assert_raises(Hive::ConfigError) do
        Hive::ManagedDirectory.new(
          root: File.join(link, "state"),
          anchor: anchor,
          label: "test state"
        ).prepare!
      end
      assert_raises(Hive::ConfigError) do
        Hive::ManagedDirectory.new(
          root: anchor,
          anchor: File.join(anchor, "outside"),
          label: "test state"
        )
      end
    end
  end

  def test_filesystem_failures_are_translated_and_owned_temporaries_are_cleaned
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      directory = Hive::ManagedDirectory.new(
        root: root,
        anchor: anchor,
        label: "test state"
      )
      native = directory.instance_variable_get(:@native)
      original_mkdir = native.method(:mkdirat)
      with_replaced_singleton_method(
        native,
        :mkdirat,
        lambda do |parent, name, mode|
          raise Errno::EIO, name if name == "state"

          original_mkdir.call(parent, name, mode)
        end
      ) do
        assert_raises(Hive::ConfigError) { directory.prepare! }
      end

      directory.prepare!
      with_replaced_singleton_method(
        native,
        :mkdirat,
        lambda do |parent, name, mode|
          raise Errno::EIO, name if name == "nested"

          original_mkdir.call(parent, name, mode)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.ensure_directory("nested")
        end
      end

      original_dir_open = native.method(:open_directory)
      with_replaced_singleton_method(
        native,
        :open_directory,
        lambda do |parent, name|
          raise Errno::EIO, name if name == "."

          original_dir_open.call(parent, name)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.each_child.to_a
        end
      end

      directory.atomic_write("record", "data")
      original_file_open = native.method(:open_file)
      with_replaced_singleton_method(
        native,
        :open_file,
        lambda do |parent, name, flags, mode: nil|
          raise Errno::EIO, name if name == "record"

          original_file_open.call(parent, name, flags, mode: mode)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.read("record", max_bytes: 4)
        end
      end

      original_rename = native.method(:renameat)
      with_replaced_singleton_method(
        native,
        :renameat,
        lambda do |source_parent, source_name, target_parent, target_name|
          raise Errno::EIO, target_name if target_name == "next"

          original_rename.call(
            source_parent,
            source_name,
            target_parent,
            target_name
          )
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.atomic_write("next", "data")
        end
      end
      refute Dir.children(root).any? { |name| name.include?(".next.json.tmp.") }
      refute Dir.children(root).any? { |name| name.start_with?(".next.tmp.") }

      invalid_content = Object.new
      invalid_content.define_singleton_method(:to_s) { raise TypeError }
      assert_raises(Hive::ConfigError) do
        directory.atomic_write("invalid", invalid_content)
      end
      refute Dir.children(root).any? { |name| name.start_with?(".invalid.tmp.") }

      with_replaced_singleton_method(
        native,
        :open_file,
        lambda do |parent, name, flags, mode: nil|
          raise Errno::EIO, name if name == "broken.lock"

          original_file_open.call(parent, name, flags, mode: mode)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.with_lock("broken.lock") { flunk "broken lock yielded" }
        end
      end

      assert_raises(Hive::ConfigError) do
        directory.relative_path(Object.new)
      end
    end
  end

  def test_directory_fsync_fallback_and_failed_cleanup_are_fail_safe
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "test state")
      native = directory.instance_variable_get(:@native)
      proxy = Object.new
      proxy.define_singleton_method(:fsync) { raise Errno::EINVAL }
      handle = Dir.open(root)
      original_for_fd = IO.method(:for_fd)
      begin
        with_replaced_singleton_method(
          IO,
          :for_fd,
          lambda do |descriptor, **keywords|
            if descriptor == handle.fileno
              proxy
            else
              original_for_fd.call(descriptor, **keywords)
            end
          end
        ) do
          assert_nil native.fsync_directory(handle)
          proxy.define_singleton_method(:fsync) { raise Errno::EBADF }
          assert_raises(Errno::EBADF) do
            native.fsync_directory(handle)
          end
        end
      ensure
        handle.close
      end

      original_rename = native.method(:renameat)
      original_unlink = native.method(:unlinkat)
      with_replaced_singleton_method(
        native,
        :renameat,
        lambda do |source_parent, source_name, target_parent, target_name|
          raise Errno::EIO, target_name if target_name == "stuck"

          original_rename.call(
            source_parent,
            source_name,
            target_parent,
            target_name
          )
        end
      ) do
        with_replaced_singleton_method(
          native,
          :unlinkat,
          lambda do |parent, name|
            raise Errno::EIO, name if name.start_with?(".stuck.tmp.")

            original_unlink.call(parent, name)
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.atomic_write("stuck", "data")
          end
        end
      end
    end
  end

  def test_missing_mode_does_not_hide_paths_that_disappear_during_use
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "test state")
      directory.atomic_write("record", "data")
      native = directory.instance_variable_get(:@native)
      original_open_file = native.method(:open_file)
      original_rename = File.method(:rename)
      parked = "#{root}.parked"

      begin
        with_replaced_singleton_method(
          native,
          :open_file,
          lambda do |parent, name, flags, mode: nil|
            file = original_open_file.call(parent, name, flags, mode: mode)
            original_rename.call(root, parked) if name == "record"
            file
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.read("record", max_bytes: 4, missing: true)
          end
        end
      ensure
        original_rename.call(parked, root) if File.directory?(parked)
      end

      original_open_directory = native.method(:open_directory)
      begin
        with_replaced_singleton_method(
          native,
          :open_directory,
          lambda do |parent, name|
            opened = original_open_directory.call(parent, name)
            original_rename.call(root, parked) if name == "."
            opened
          end
        ) do
          assert_raises(Hive::ConfigError) do
            directory.each_child(".", missing: true).to_a
          end
        end
      ensure
        original_rename.call(parked, root) if File.directory?(parked)
      end
    end
  end

  def test_fails_closed_when_no_follow_is_unavailable
    original = File::Constants.const_get(:NOFOLLOW)
    File::Constants.send(:remove_const, :NOFOLLOW)
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      assert_raises(Hive::ConfigError) do
        Hive::ManagedDirectory.new(
          root: root,
          anchor: anchor,
          label: "test state"
        )
      end
      refute_path_exists root
    end
  ensure
    File::Constants.const_set(:NOFOLLOW, original) if original
  end

  private

  def file_identity_and_digest(path)
    stat = File.stat(path)
    [
      stat.dev,
      stat.ino,
      stat.size,
      Digest::SHA256.file(path).hexdigest
    ]
  end
end
