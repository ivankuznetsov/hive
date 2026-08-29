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

  private

  def store(root, **options)
    Hive::RuntimeControlPlane::PayloadStore.new(
      root: File.join(root, "payloads"), **options
    )
  end
end
