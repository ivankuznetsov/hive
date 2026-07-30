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
      assert_equal :directory, directory.entry_type("nested/records")
      assert_equal(
        File.join(root, "nested", "records", "one.json"),
      directory.atomic_write("nested/records/one.json", "one", mode: 0o600)
      )
      assert_equal :regular,
                   directory.entry_type("nested/records/one.json")
      assert_nil directory.entry_type(
        "nested/records/missing.json", missing: true
      )
      assert_equal "one", directory.read("nested/records/one.json", max_bytes: 3)
      snapshot = directory.read_with_metadata(
        "nested/records/one.json", max_bytes: 3
      )
      assert_equal "one", snapshot.fetch(:bytes)
      assert_equal 0o600, snapshot.fetch(:mode)
      assert_equal(
        File.stat(
          File.join(root, "nested", "records", "one.json")
        ).mtime.utc,
        snapshot.fetch(:mtime)
      )
      preserved_mtime = Time.at(
        Time.utc(2026, 7, 29, 12, 0, 0).to_i,
        123_456_789,
        :nsec
      ).utc
      directory.atomic_write(
        "nested/records/timed.json",
        "timed",
        mode: 0o640,
        mtime: preserved_mtime
      )
      timed = directory.read_with_metadata(
        "nested/records/timed.json", max_bytes: 5
      )
      assert_equal 0o640, timed.fetch(:mode)
      assert_equal preserved_mtime, timed.fetch(:mtime)
      assert_nil directory.read("nested/records/missing.json", max_bytes: 3, missing: true)
      assert_equal [ "one.json", "timed.json" ],
                   directory.each_child("nested/records").to_a.sort
      assert_equal 0o700, File.stat(File.join(root, "nested")).mode & 0o777
      assert_equal 0o600,
                   File.stat(File.join(root, "nested", "records", "one.json")).mode & 0o777

      locked = false
      directory.with_lock("state.lock") { locked = true }
      assert locked
      assert_equal 0o600, File.stat(File.join(root, "state.lock")).mode & 0o777

      error = assert_raises(IOError) do
        directory.with_lock("state.lock") do
          raise IOError, "operation failed while locked"
        end
      end
      assert_equal "operation failed while locked", error.message
    end
  end

  def test_directory_metadata_is_missing_aware_and_translates_failures
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      nested = File.join(root, "nested")
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      directory.ensure_directory("nested")
      File.chmod(0o750, nested)

      metadata = directory.directory_metadata("nested")
      assert_equal 0o750, metadata.fetch(:mode)
      assert_equal File.stat(nested).mtime.utc, metadata.fetch(:mtime)
      assert_nil directory.directory_metadata("missing", missing: true)
      assert_raises(Hive::ConfigError) do
        directory.directory_metadata("missing")
      end
      assert_raises(Hive::ConfigError) do
        directory.directory_metadata("../outside")
      end

      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_directory)
      with_replaced_singleton_method(
        native,
        :open_directory,
        lambda do |parent, name|
          raise Errno::EIO, name if name == "broken"

          original_open.call(parent, name)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.directory_metadata("broken")
        end
      end

      nested_opens = 0
      with_replaced_singleton_method(
        native,
        :open_directory,
        lambda do |parent, name|
          if name == "nested"
            nested_opens += 1
            raise Errno::ENOENT, name if nested_opens == 2
          end

          original_open.call(parent, name)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.directory_metadata("nested")
        end
      end
    end
  end

  def test_entry_type_translates_each_missing_and_unsafe_failure
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "test state")

      assert_raises(Hive::ConfigError) do
        directory.entry_type("missing-parent/record")
      end
      assert_raises(Hive::ConfigError) do
        directory.entry_type("missing-record")
      end
      assert_raises(Hive::ConfigError) { directory.entry_type(".") }

      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_directory)
      with_replaced_singleton_method(
        native,
        :open_directory,
        lambda do |parent, name|
          raise Errno::EIO, name if name == "broken"

          original_open.call(parent, name)
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.entry_type("broken")
        end
      end
    end
  end

  def test_atomically_exchanges_a_directory_with_a_regular_tombstone
    with_tmp_dir do |root|
      legacy = File.join(root, "v2")
      archive = File.join(root, ".v2-cutover")
      FileUtils.mkdir_p(File.join(legacy, "jobs"))
      File.binwrite(File.join(legacy, "jobs", "one.json"), "legacy")
      File.binwrite(archive, "tombstone")
      legacy_identity = File.stat(legacy).then { |stat| [ stat.dev, stat.ino ] }
      tombstone_identity =
        File.stat(archive).then { |stat| [ stat.dev, stat.ino ] }
      directory = Hive::ManagedDirectory.new(
        root: root, label: "schema cutover"
      )

      result = directory.exchange_directory_with_regular!(
        directory_name: "v2", regular_name: ".v2-cutover"
      )

      assert_equal File.join(root, "v2"), result.fetch(:tombstone_path)
      assert_equal File.join(root, ".v2-cutover"),
                   result.fetch(:archive_path)
      assert File.file?(File.join(root, "v2"))
      assert_equal "tombstone", File.binread(File.join(root, "v2"))
      assert File.directory?(File.join(root, ".v2-cutover"))
      assert_equal "legacy",
                   File.binread(File.join(root, ".v2-cutover", "jobs", "one.json"))
      assert_equal tombstone_identity,
                   File.stat(File.join(root, "v2")).then { |stat| [ stat.dev, stat.ino ] }
      assert_equal legacy_identity,
                   File.stat(File.join(root, ".v2-cutover")).then { |stat| [ stat.dev, stat.ino ] }
    end
  end

  def test_atomic_exchange_fails_closed_without_platform_support
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "v2"))
      File.binwrite(File.join(root, ".v2-cutover"), "tombstone")
      directory = Hive::ManagedDirectory.new(
        root: root, label: "schema cutover"
      )
      native = directory.instance_variable_get(:@native)
      unavailable = native.class.const_get(:Unavailable)

      with_replaced_singleton_method(
        native,
        :exchangeat,
        ->(*) { raise unavailable }
      ) do
        error = assert_raises(
          Hive::ManagedDirectory::ExchangeUnavailable
        ) do
          directory.exchange_directory_with_regular!(
            directory_name: "v2", regular_name: ".v2-cutover"
          )
        end
        assert_match(/requires atomic filesystem exchange/, error.message)
      end

      assert File.directory?(File.join(root, "v2"))
      assert_equal "tombstone", File.binread(File.join(root, ".v2-cutover"))
    end
  end

  def test_atomic_exchange_translates_missing_and_filesystem_failures
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "v2"))
      directory = Hive::ManagedDirectory.new(
        root: root, label: "schema cutover"
      )

      assert_raises(Hive::ConfigError) do
        directory.exchange_directory_with_regular!(
          directory_name: "v2", regular_name: ".missing-cutover"
        )
      end

      tombstone = File.join(root, ".v2-cutover")
      File.binwrite(tombstone, "tombstone")
      native = directory.instance_variable_get(:@native)
      with_replaced_singleton_method(
        native,
        :exchangeat,
        ->(*) { raise Errno::EIO, "atomic exchange" }
      ) do
        assert_raises(Hive::ConfigError) do
          directory.exchange_directory_with_regular!(
            directory_name: "v2", regular_name: ".v2-cutover"
          )
        end
      end

      assert File.directory?(File.join(root, "v2"))
      assert_equal "tombstone", File.binread(tombstone)
    end
  end

  def test_quarantines_live_child_and_activates_replacement
    with_tmp_dir do |root|
      live = File.join(root, "current")
      replacement = File.join(root, "replacement")
      FileUtils.mkdir_p(live)
      FileUtils.mkdir_p(replacement)
      File.binwrite(File.join(live, "record"), "old")
      File.binwrite(File.join(replacement, "record"), "new")
      directory = Hive::ManagedDirectory.new(
        root: root, label: "schema cutover"
      )

      quarantined = directory.quarantine_and_replace_child!(
        live_name: "current",
        replacement_name: "replacement",
        quarantine_directory: "quarantine",
        quarantine_name: "old-generation"
      )

      assert_equal File.join(root, "quarantine", "old-generation"),
                   quarantined
      assert_equal "new", File.binread(File.join(root, "current", "record"))
      assert_equal "old", File.binread(File.join(quarantined, "record"))
      refute_path_exists replacement
    end
  end

  def test_quarantine_replacement_rejects_missing_or_occupied_entries
    with_tmp_dir do |root|
      replacement = File.join(root, "replacement")
      FileUtils.mkdir_p(replacement)
      directory = Hive::ManagedDirectory.new(
        root: root, label: "schema cutover"
      )

      assert_raises(Hive::ConfigError) do
        directory.quarantine_and_replace_child!(
          live_name: "missing",
          replacement_name: "replacement",
          quarantine_directory: "quarantine",
          quarantine_name: "old-generation"
        )
      end

      live = File.join(root, "current")
      FileUtils.mkdir_p(live)
      FileUtils.mkdir_p(File.join(root, "quarantine"))
      File.binwrite(
        File.join(root, "quarantine", "old-generation"),
        "occupied"
      )
      assert_raises(Hive::ConfigError) do
        directory.quarantine_and_replace_child!(
          live_name: "current",
          replacement_name: "replacement",
          quarantine_directory: "quarantine",
          quarantine_name: "old-generation"
        )
      end
    end
  end

  def test_quarantine_replacement_rolls_back_when_activation_fails
    with_tmp_dir do |root|
      live = File.join(root, "current")
      replacement = File.join(root, "replacement")
      FileUtils.mkdir_p(live)
      FileUtils.mkdir_p(replacement)
      File.binwrite(File.join(live, "record"), "old")
      File.binwrite(File.join(replacement, "record"), "new")
      directory = Hive::ManagedDirectory.new(
        root: root, label: "schema cutover"
      )
      native = directory.instance_variable_get(:@native)
      original_rename = native.method(:renameat)

      with_replaced_singleton_method(
        native,
        :renameat,
        lambda do |source_parent, source_name, target_parent, target_name|
          if source_name == "replacement" && target_name == "current"
            raise Errno::EIO, target_name
          end

          original_rename.call(
            source_parent,
            source_name,
            target_parent,
            target_name
          )
        end
      ) do
        assert_raises(Hive::ConfigError) do
          directory.quarantine_and_replace_child!(
            live_name: "current",
            replacement_name: "replacement",
            quarantine_directory: "quarantine",
            quarantine_name: "old-generation"
          )
        end
      end

      assert_equal "old", File.binread(File.join(live, "record"))
      assert_equal "new", File.binread(File.join(replacement, "record"))
      refute_path_exists File.join(root, "quarantine", "old-generation")
    end
  end

  def test_quarantines_one_directory_without_a_replacement
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "v3", "jobs"))
      File.binwrite(File.join(root, "v3", "jobs", "one.json"), "current")
      directory = Hive::ManagedDirectory.new(
        root: root, label: "schema rollback"
      )

      quarantined = directory.quarantine_child!(
        live_name: "v3",
        quarantine_directory: "rollback-quarantine",
        quarantine_name: "snapshot-a"
      )

      refute_path_exists File.join(root, "v3")
      assert_equal(
        File.join(root, "rollback-quarantine", "snapshot-a"),
        quarantined
      )
      assert_equal(
        "current",
        File.binread(File.join(quarantined, "jobs", "one.json"))
      )
      assert_raises(Hive::ConfigError) do
        directory.quarantine_child!(
          live_name: "missing",
          quarantine_directory: "rollback-quarantine",
          quarantine_name: "snapshot-b"
        )
      end
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

  def test_try_with_lock_returns_without_yielding_when_an_owner_exists
    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      )
      directory.prepare!
      lock_path = File.join(root, "state.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |owner|
        owner.flock(File::LOCK_EX)
        yielded = false

        assert_equal false, directory.try_with_lock("state.lock") {
          yielded = true
        }
        refute yielded
      end

      assert_equal :owned, directory.try_with_lock("state.lock") { :owned }
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

  def test_treats_raced_directory_creation_and_bad_digest_limits_as_unsafe
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      native = directory.instance_variable_get(:@native)
      original_mkdirat = native.method(:mkdirat)

      with_replaced_singleton_method(
        native,
        :mkdirat,
        lambda do |parent, name, mode|
          original_mkdirat.call(parent, name, mode)
          raise Errno::EEXIST, name if %w[state nested].include?(name)
        end
      ) do
        directory.prepare!
        assert_equal File.join(root, "nested"),
                     directory.ensure_directory("nested")
      end

      directory.atomic_write("record", "before")
      assert_raises(Hive::ConfigError) do
        directory.atomic_write(
          "record",
          "after",
          expected_digest: Digest::SHA256.hexdigest("before"),
          max_existing_bytes: Object.new
        )
      end
      assert_raises(Hive::ConfigError) { directory.ensure_directory("../unsafe") }
    end
  end

  def test_unlink_missing_mode_handles_a_missing_root_without_creating_it
    with_tmp_dir do |anchor|
      root = File.join(anchor, "missing")
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )

      refute directory.unlink("record", missing: true)
      refute_path_exists root
    end
  end

  def test_unlink_translates_missing_entries_and_late_enoent_failures
    with_tmp_dir do |anchor|
      missing = Hive::ManagedDirectory.new(
        root: File.join(anchor, "missing"), anchor: anchor, label: "test state"
      )
      assert_raises(Hive::ConfigError) { missing.unlink("record") }

      directory = Hive::ManagedDirectory.new(root: anchor, label: "test state")
      directory.atomic_write("record", "data")
      native = directory.instance_variable_get(:@native)
      original_unlinkat = native.method(:unlinkat)
      with_replaced_singleton_method(
        native,
        :unlinkat,
        lambda do |parent, name|
          raise Errno::ENOENT, name if name == "record"

          original_unlinkat.call(parent, name)
        end
      ) do
        assert_raises(Hive::ConfigError) { directory.unlink("record") }
      end
      assert_equal "data", directory.read("record", max_bytes: 4)
    end
  end

  def test_descriptor_cleanup_failures_do_not_hide_safe_operation_results
    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      FileUtils.mkdir_p(File.join(root, "nested"))
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_directory)
      proxy_builder = method(:close_failure_proxy)
      handles = []
      with_replaced_singleton_method(
        native,
        :open_directory,
        lambda do |parent, name|
          handle = original_open.call(parent, name)
          next handle unless name == "nested"

          handles << proxy_builder.call(handle)
          handles.last
        end
      ) do
        assert_equal File.join(root, "nested"),
                     directory.ensure_directory("nested")
      end
      handles.each { |handle| handle.close_underlying }
    end

    with_tmp_dir do |anchor|
      root = File.join(anchor, "state")
      FileUtils.mkdir_p(root)
      directory = Hive::ManagedDirectory.new(
        root: root, anchor: anchor, label: "test state"
      )
      native = directory.instance_variable_get(:@native)
      original_open = native.method(:open_directory)
      proxy_builder = method(:close_failure_proxy)
      handles = []
      with_replaced_singleton_method(
        native,
        :open_directory,
        lambda do |parent, name|
          handle = original_open.call(parent, name)
          next handle unless name == "state"

          handles << proxy_builder.call(handle)
          handles.last
        end
      ) do
        assert_same directory, directory.prepare!
      end
      handles.each { |handle| handle.close_underlying }
    end
  end

  def test_native_adapter_fails_closed_when_runtime_descriptor_setup_breaks
    original_function = Fiddle::Function.method(:new)
    with_replaced_singleton_method(
      Fiddle::Function,
      :new,
      lambda do |*arguments, **keywords|
        raise Fiddle::DLError, "missing openat"
      end
    ) do
      with_tmp_dir do |root|
        assert_raises(Hive::ConfigError) do
          Hive::ManagedDirectory.new(root: root, label: "test state")
        end
      end
    end
  ensure
    Fiddle::Function.define_singleton_method(:new, original_function)

    with_tmp_dir do |root|
      directory = Hive::ManagedDirectory.new(root: root, label: "test state")
      native = directory.instance_variable_get(:@native)
      original_sysopen = IO.method(:sysopen)
      original_for_fd = IO.method(:for_fd)
      fd = nil
      with_replaced_singleton_method(
        IO,
        :sysopen,
        lambda do |*arguments, **keywords|
          fd = original_sysopen.call(*arguments, **keywords)
        end
      ) do
        with_replaced_singleton_method(
          Dir,
          :for_fd,
          ->(_descriptor) { raise IOError, "directory wrapper failed" }
        ) do
          with_replaced_singleton_method(
            IO,
            :for_fd,
            lambda do |descriptor, **keywords|
              if descriptor == fd && keywords.empty?
                Object.new.tap do |proxy|
                  proxy.define_singleton_method(:close) do
                    raise IOError, "descriptor close failed"
                  end
                end
              else
                original_for_fd.call(descriptor, **keywords)
              end
            end
          ) do
            assert_raises(Hive::ConfigError) { directory.prepare! }
          end
        end
      end
      original_for_fd.call(fd).close if fd
      assert native
    end
  end

  def test_native_adapter_selects_exact_supported_platform_flags
    with_tmp_dir do |root|
      native = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      ).instance_variable_get(:@native)

      assert_equal(
        { directory: 0o200000, cloexec: 0o2000000 },
        native.class.platform_flags("x86_64-linux")
      )
      assert_equal(
        { directory: 0x00100000, cloexec: 0x01000000 },
        native.class.platform_flags("arm64-darwin")
      )
      assert_nil native.class.platform_flags("java")
    end
  end

  def test_native_adapter_treats_an_optional_missing_symbol_as_unavailable
    with_tmp_dir do |root|
      native = Hive::ManagedDirectory.new(
        root: root, label: "test state"
      ).instance_variable_get(:@native)

      with_replaced_singleton_method(
        native,
        :function,
        ->(*) { raise Fiddle::DLError, "missing optional symbol" }
      ) do
        assert_nil native.send(
          :optional_function, Fiddle::Handle::DEFAULT, "optional", []
        )
      end
    end
  end

  private

  def close_failure_proxy(handle)
    proxy = Object.new
    proxy.define_singleton_method(:fileno) { handle.fileno }
    proxy.define_singleton_method(:close) { raise IOError, "close failed" }
    proxy.define_singleton_method(:close_underlying) { handle.close }
    proxy
  end

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
