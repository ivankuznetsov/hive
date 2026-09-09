require "test_helper"
require "fileutils"
require "hive/runtime_control_plane/payload_store"

class RuntimeControlPlanePayloadStoreTest < Minitest::Test
  include HiveTestHelper

  def test_open_payload_seals_to_immutable_content_address_and_round_trips
    with_tmp_dir do |root|
      store = store(root)
      open_path = store.write_open(attempt_id: "attempt-1", name: "worker.frames", bytes: "hello\n")
      refute_includes open_path, Digest::SHA256.hexdigest("hello\n")

      reference = store.seal(open_path)
      assert_equal Digest::SHA256.hexdigest("hello\n"), reference.fetch("sha256")
      assert_equal 6, reference.fetch("size")
      assert_equal "hello\n", store.read_sealed(reference)
      assert_equal reference, store.seal(open_path)
      assert_equal 0o600, File.stat(store.path_for(reference)).mode & 0o777
      assert_equal 1, File.stat(store.path_for(reference)).nlink
    end
  end

  def test_empty_payload_seals_reuses_and_round_trips
    with_tmp_dir do |root|
      subject = store(root)
      first = subject.write_open(attempt_id: "attempt-1", name: "worker.frames", bytes: "")
      reference = subject.seal(first)

      assert_equal Digest::SHA256.hexdigest(""), reference.fetch("sha256")
      assert_equal 0, reference.fetch("size")
      assert_equal "", subject.read_sealed(reference)

      second = subject.write_open(attempt_id: "attempt-2", name: "worker.frames", bytes: "")
      assert_equal reference, subject.seal(second)
      assert_equal "", subject.read_sealed(reference)
    end
  end

  def test_traversal_symlinks_and_hardlinks_are_rejected
    with_tmp_dir do |root|
      store = store(root)
      assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) do
        store.write_open(attempt_id: "../escape", name: "out", bytes: "x")
      end

      source = File.join(root, "source")
      File.binwrite(source, "bytes")
      symlink = File.join(root, "symlink")
      File.symlink(source, symlink)
      assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) { store.seal(symlink) }

      hardlink = File.join(root, "hardlink")
      File.link(source, hardlink)
      assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) { store.seal(source) }
    end
  end

  def test_source_mutation_during_copy_fails_closed
    with_tmp_dir do |root|
      source = File.join(root, "source")
      File.binwrite(source, "before")
      store = store(root, after_copy: -> { File.binwrite(source, "after") })

      error = assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
        store.seal(source)
      end
      assert_equal :source_changed, error.code
      assert_empty Dir.glob(File.join(root, "payloads", "sealed", "sha256", "**", "*"))
    end
  end

  def test_missing_or_corrupt_sealed_payload_is_typed
    with_tmp_dir do |root|
      store = store(root)
      source = store.write_open(attempt_id: "attempt-1", name: "out", bytes: "payload")
      reference = store.seal(source)
      File.binwrite(store.path_for(reference), "corrupt")

      error = assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
        store.read_sealed(reference)
      end
      assert_equal :payload_digest_mismatch, error.code
      File.unlink(store.path_for(reference))
      error = assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
        store.read_sealed(reference)
      end
      assert_equal :payload_missing, error.code
    end
  end

  def test_reconciliation_reclaims_only_conclusively_lost_attempts
    with_tmp_dir do |root|
      store = store(root)
      lost = store.write_open(attempt_id: "lost", name: "out", bytes: "lost")
      live = store.write_open(attempt_id: "live", name: "out", bytes: "live")

      assert_equal [ lost ], store.reclaim_open!(lost_attempt_ids: [ "lost" ])
      refute_path_exists lost
      assert_path_exists live
    end
  end

  def test_open_write_and_seal_io_failures_are_typed
    with_tmp_dir do |root|
      subject = store(root)
      failure = ->(*) { raise IOError, "write failed" }
      error = with_replaced_singleton_method(Hive::AtomicFile, :write, failure) do
        assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) do
          subject.write_open(attempt_id: "attempt", name: "out", bytes: "data")
        end
      end
      assert_equal :payload_write_failed, error.code

      source = File.join(root, "source")
      File.binwrite(source, "data")
      original = File.method(:open)
      unsafe = lambda do |path, *arguments, &block|
        raise Errno::ELOOP, path if path == source

        original.call(path, *arguments, &block)
      end
      error = with_replaced_singleton_method(File, :open, unsafe) do
        assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) { subject.seal(source) }
      end
      assert_equal :unsafe_payload_path, error.code

      error = assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
        subject.seal(source, expected_size: Object.new)
      end
      assert_equal :payload_seal_failed, error.code
    end
  end

  def test_link_race_verifies_the_existing_content_address
    with_tmp_dir do |root|
      subject = store(root)
      source = subject.write_open(attempt_id: "attempt", name: "out", bytes: "data")
      reference = subject.seal(source)
      destination = subject.path_for(reference)
      original = subject.method(:optional_lstat)
      subject.define_singleton_method(:optional_lstat) do |path|
        path == destination ? nil : original.call(path)
      end

      assert_equal reference, subject.seal(source)
    end
  end

  def test_reference_shape_path_and_missing_resolution_fail_closed
    with_tmp_dir do |root|
      subject = store(root)
      source = subject.write_open(attempt_id: "attempt", name: "out", bytes: "data")
      reference = subject.seal(source)
      invalid = [ Object.new, reference.merge("algorithm" => "md5"), reference.merge("size" => Object.new) ]
      invalid.each do |value|
        error = assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
          subject.read_sealed(value)
        end
        assert_equal :payload_reference_invalid, error.code
      end
      error = assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) do
        subject.path_for(reference.merge("path" => "sealed/wrong"))
      end
      assert_equal :payload_path_mismatch, error.code

      subject.define_singleton_method(:path_for) { |_| raise Errno::ENOENT }
      error = assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
        subject.read_sealed(reference)
      end
      assert_equal :payload_missing, error.code
    end
  end

  def test_read_detects_inode_and_snapshot_changes
    with_tmp_dir do |root|
      subject = store(root)
      source = subject.write_open(attempt_id: "attempt", name: "out", bytes: "data")
      reference = subject.seal(source)
      path = subject.path_for(reference)
      original = File.method(:lstat)
      calls = 0
      changed = lambda do |candidate|
        status = original.call(candidate)
        if candidate == path
          calls += 1
          if calls == 2
            return Struct.new(:file?, :symlink?, :nlink, :uid, :size, :dev, :ino, :mtime, :ctime)
              .new(true, false, 1, status.uid, status.size, status.dev, status.ino,
                   status.mtime, status.ctime + 1)
          end
        end
        status
      end
      error = with_replaced_singleton_method(File, :lstat, changed) do
        assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
          subject.read_sealed(reference)
        end
      end
      assert_equal :payload_changed, error.code

      mismatch = lambda do |candidate|
        status = original.call(candidate)
        if candidate == path
          Struct.new(:file?, :symlink?, :nlink, :uid, :size, :dev, :ino, :mtime, :ctime)
            .new(true, false, 1, status.uid, status.size, status.dev, status.ino + 1,
                 status.mtime, status.ctime)
        else
          status
        end
      end
      error = with_replaced_singleton_method(File, :lstat, mismatch) do
        assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) do
          subject.read_sealed(reference)
        end
      end
      assert_equal :source_changed, error.code
    end
  end

  def test_custody_reference_and_lock_shape_are_typed
    with_tmp_dir do |root|
      subject = store(root)
      assert_raises(Hive::RuntimeControlPlane::PayloadStore::IntegrityError) do
        subject.with_reference_custody([ "bad" ]) { flunk "must not enter custody" }
      end

      digest = "a" * 64
      lock_path = File.join(root, "payloads", ".custody", "aa.lock")
      original = File.method(:lstat)
      unsafe = lambda do |path|
        status = original.call(path)
        path == lock_path ? Struct.new(:file?, :symlink?, :nlink, :uid, :dev, :ino)
          .new(false, false, 1, Process.euid, status.dev, status.ino) : status
      end
      error = with_replaced_singleton_method(File, :lstat, unsafe) do
        assert_raises(Hive::RuntimeControlPlane::PayloadStore::PathError) do
          subject.with_reference_custody([ digest ]) { flunk "must not enter custody" }
        end
      end
      assert_equal :unsafe_payload_custody, error.code
    end
  end

  private

  def store(root, **options)
    Hive::RuntimeControlPlane::PayloadStore.new(
      root: File.join(root, "payloads"), **options
    )
  end
end
