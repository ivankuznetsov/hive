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
      original_open = File.method(:open)

      with_replaced_singleton_method(
        File,
        :open,
        lambda do |path, *arguments, **keywords, &block|
          unless File.basename(path).start_with?(".record.tmp.")
            next original_open.call(
              path, *arguments, **keywords, &block
            )
          end

          result = original_open.call(
            path, *arguments, **keywords, &block
          )
          original_open.call(
            target, File::WRONLY | File::TRUNC
          ) { |file| file.write("raced!") }
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

  def test_successful_unlink_fsyncs_its_verified_parent
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      )
      File.write(File.join(root, "record"), "retire")
      calls = []
      directory.define_singleton_method(:fsync_directory) do |path, stat|
        calls << [ path, stat.dev, stat.ino ]
      end

      assert directory.unlink("record")
      assert_equal 1, calls.size
      assert_equal root, calls.first.first
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
      original_mkdir = Dir.method(:mkdir)
      with_replaced_singleton_method(
        Dir,
        :mkdir,
        lambda do |path, *arguments|
          raise Errno::EIO, path if path == root

          original_mkdir.call(path, *arguments)
        end
      ) do
        assert_raises(Hive::ConfigError) { directory.prepare! }
      end

      directory.prepare!
      nested = File.join(root, "nested")
      with_replaced_singleton_method(
        Dir,
        :mkdir,
        lambda do |path, *arguments|
          raise Errno::EIO, path if path == nested

          original_mkdir.call(path, *arguments)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.ensure_directory("nested")
        end
      end

      original_dir_open = Dir.method(:open)
      with_replaced_singleton_method(
        Dir,
        :open,
        lambda do |path, *arguments, &block|
          raise Errno::EIO, path if path == root

          original_dir_open.call(path, *arguments, &block)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.each_child.to_a
        end
      end

      directory.atomic_write("record", "data")
      original_file_open = File.method(:open)
      with_replaced_singleton_method(
        File,
        :open,
        lambda do |path, *arguments, **keywords, &block|
          raise Errno::EIO, path if path == File.join(root, "record")

          original_file_open.call(path, *arguments, **keywords, &block)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.read("record", max_bytes: 4)
        end
      end

      original_rename = File.method(:rename)
      with_replaced_singleton_method(
        File,
        :rename,
        lambda do |source, destination|
          raise Errno::EIO, destination if destination == File.join(root, "next")

          original_rename.call(source, destination)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.atomic_write("next", "data")
        end
      end
      refute Dir.children(root).any? { |name| name.include?(".next.json.tmp.") }
      refute Dir.children(root).any? { |name| name.start_with?(".next.tmp.") }

      lock_path = File.join(root, "broken.lock")
      with_replaced_singleton_method(
        File,
        :open,
        lambda do |path, *arguments, **keywords, &block|
          raise Errno::EIO, path if path == lock_path

          original_file_open.call(path, *arguments, **keywords, &block)
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
      stat = File.lstat(root)
      proxy = Object.new
      proxy.define_singleton_method(:stat) { stat }
      proxy.define_singleton_method(:fsync) { raise Errno::EINVAL }
      original_open = File.method(:open)
      with_replaced_singleton_method(
        File,
        :open,
        lambda do |path, *arguments, **keywords, &block|
          if path == root
            block.call(proxy)
          else
            original_open.call(path, *arguments, **keywords, &block)
          end
        end
      ) do
        assert_nil directory.send(:fsync_directory, root, stat)
      end

      original_rename = File.method(:rename)
      original_unlink = File.method(:unlink)
      with_replaced_singleton_method(
        File,
        :rename,
        lambda do |source, destination|
          raise Errno::EIO, destination if destination == File.join(root, "stuck")

          original_rename.call(source, destination)
        end
      ) do
        with_replaced_singleton_method(
          File,
          :unlink,
          lambda do |path|
            raise Errno::EIO, path if File.basename(path).start_with?(".stuck.tmp.")

            original_unlink.call(path)
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
      original_lstat = File.method(:lstat)

      root_checks = 0
      with_replaced_singleton_method(
        File,
        :lstat,
        lambda do |path|
          root_checks += 1 if path == root
          raise Errno::ENOENT, path if path == root && root_checks == 2

          original_lstat.call(path)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.read("record", max_bytes: 4, missing: true)
        end
      end

      root_checks = 0
      with_replaced_singleton_method(
        File,
        :lstat,
        lambda do |path|
          root_checks += 1 if path == root
          raise Errno::ENOENT, path if path == root && root_checks == 2

          original_lstat.call(path)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.each_child(".", missing: true).to_a
        end
      end
    end
  end

  def test_fails_closed_when_no_follow_is_unavailable
    original = File::Constants.const_get(:NOFOLLOW)
    File::Constants.send(:remove_const, :NOFOLLOW)
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "test state")
      assert_raises(Hive::ConfigError) { directory.send(:nofollow) }
    end
  ensure
    File::Constants.const_set(:NOFOLLOW, original) if original
  end
end
