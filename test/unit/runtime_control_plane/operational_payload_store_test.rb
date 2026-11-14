require "test_helper"
require "digest"
require "hive/runtime_control_plane/operational_payload_store"

class RuntimeOperationalPayloadStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 11, 14, 10)

  def test_write_skips_unchanged_content_and_read_verifies_the_reference
    with_tmp_dir do |root|
      store = store_for(root)
      bytes = %({"projects":[]})
      digest = Digest::SHA256.hexdigest(bytes)

      assert store.write(digest, bytes)
      refute store.write(digest, bytes), "the same content address is not rewritten"
      assert_equal bytes, store.read(digest, bytes.bytesize)
      assert_equal Encoding::UTF_8, store.read(digest, bytes.bytesize).encoding
      assert_equal 0o600, File.stat(File.join(store.root, "#{digest}.json")).mode & 0o777
      assert_equal 0o700, File.stat(store.root).mode & 0o777

      [ nil, -1, "15" ].each do |size|
        error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { store.read(digest, size) }
        assert_equal :projection_payload_mismatch, error.code
      end
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { store.read("not-a-digest", 15) }
      assert_equal :projection_payload_mismatch, error.code
    end
  end

  def test_prune_keeps_referenced_payloads_and_fresh_temporaries
    with_tmp_dir do |root|
      store = store_for(root)
      kept, dropped = %w[kept dropped].map do |content|
        Digest::SHA256.hexdigest(content).tap { |digest| store.write(digest, content) }
      end
      stale = File.join(store.root, ".#{kept}.json.tmp.1.aaaa")
      fresh = File.join(store.root, ".#{kept}.json.tmp.2.bbbb")
      unrelated = File.join(store.root, "notes.txt")
      [ stale, fresh, unrelated ].each { |path| File.write(path, "x") }
      File.utime(NOW - 3600, NOW - 3600, stale)
      File.utime(NOW, NOW, fresh)
      # A payload-named directory cannot be unlinked; pruning skips it.
      stuck = File.join(store.root, "#{'f' * 64}.json")
      Dir.mkdir(stuck)

      assert store.prune(keep: [ kept ])

      assert_equal [ ".#{kept}.json.tmp.2.bbbb", "#{kept}.json", "#{'f' * 64}.json", "notes.txt" ],
                   Dir.children(store.root).sort
      refute_includes Dir.children(store.root), "#{dropped}.json"
      assert store.write(dropped, "dropped"), "a pruned address is written again"
    end
  end

  def test_prune_of_a_missing_root_is_a_no_op
    with_tmp_dir do |root|
      refute store_for(root).prune(keep: [])
    end
  end

  private

  def store_for(root)
    Hive::RuntimeControlPlane::OperationalPayloadStore.new(
      root: File.join(root, "operational-status-payloads"), clock: -> { NOW }
    )
  end
end
