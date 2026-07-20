require "test_helper"
require "json"
require "tmpdir"
require "hive/bot/pairing_store"

class HiveBotPairingStoreTest < Minitest::Test
  STORE = Hive::Bot::PairingStore

  def test_mint_or_get_reuses_unexpired_code_for_same_chat
    Dir.mktmpdir("hive-pairing-store") do |dir|
      now = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { now })

      first = store.mint_or_get(chat_id: 111)
      repeat = store.mint_or_get(chat_id: 111)
      now += 1
      other = store.mint_or_get(chat_id: 222)

      assert_equal first, repeat
      refute_equal first, other
      assert_match(/\A[A-Z]{8}\z/, first)
      assert_equal [ 111, 222 ], store.pending.map(&:chat_id)
    end
  end

  def test_expired_pending_entry_is_pruned_and_new_code_is_minted
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      first = store.mint_or_get(chat_id: 111)

      current += STORE::EXPIRY_SEC + 1
      assert_empty store.pending
      replacement = store.mint_or_get(chat_id: 111)

      refute_equal first, replacement
      assert_equal [ replacement ], store.pending.map(&:code)
    end
  end

  def test_resolve_peeks_without_consuming
    Dir.mktmpdir("hive-pairing-store") do |dir|
      store = STORE.new(state_home: dir, now: -> { Time.utc(2026, 6, 30, 12, 0, 0) })
      code = store.mint_or_get(chat_id: 111)

      assert_equal 111, store.resolve(code: code)
      assert_equal 111, store.resolve(code: code), "resolve must not delete the entry"
      assert_equal [ 111 ], store.pending.map(&:chat_id)
    end
  end

  def test_resolve_distinguishes_expired_blank_and_missing
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      code = store.mint_or_get(chat_id: 111)

      assert_equal :unknown, store.resolve(code: "")
      assert_equal :unknown, store.resolve(code: "ZZZZZZZZ")
      current += STORE::EXPIRY_SEC + 1
      assert_equal :expired, store.resolve(code: code), "resolve reports expiry without deleting"
    end
  end

  def test_resolve_prunes_expired_siblings_on_miss
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      expiring = store.mint_or_get(chat_id: 111)
      current += STORE::EXPIRY_SEC + 1

      assert_equal :unknown, store.resolve(code: "ZZZZZZZZ")

      doc = JSON.parse(File.read(File.join(dir, STORE::FILENAME)))
      refute doc.key?(expiring), "a miss must prune expired siblings from disk"
    end
  end

  def test_consume_is_idempotent_and_ignores_blank
    Dir.mktmpdir("hive-pairing-store") do |dir|
      store = STORE.new(state_home: dir, now: -> { Time.utc(2026, 6, 30, 12, 0, 0) })
      code = store.mint_or_get(chat_id: 111)

      assert_equal false, store.consume(code: ""), "blank code consumes nothing"
      assert_equal false, store.consume(code: "ZZZZZZZZ"), "missing code consumes nothing"
      assert_equal true, store.consume(code: code)
      assert_equal false, store.consume(code: code), "second consume is a no-op"
      assert_empty store.pending
    end
  end

  def test_pending_does_not_rewrite_when_nothing_is_pruned
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      store.mint_or_get(chat_id: 111)
      path = File.join(dir, STORE::FILENAME)

      # Observe the real side effect (the atomic tmp+rename swaps the inode)
      # rather than spying on the private write_entries — the assertion then
      # survives any refactor of how the write happens, and the inode check is
      # immune to coarse mtime granularity.
      ino_before = File.stat(path).ino
      store.pending
      assert_equal ino_before, File.stat(path).ino,
                   "a no-prune read must not rewrite (rename) the backing file"

      current += STORE::EXPIRY_SEC + 1
      store.pending
      assert File.exist?(path), "the pruned store is rewritten in place, not deleted"
      refute_equal ino_before, File.stat(path).ino,
                   "a read that prunes an expired entry persists the change (new inode)"
    end
  end

  def test_mint_or_get_persists_prune_of_expired_sibling_on_reuse
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      expiring = store.mint_or_get(chat_id: 111)
      current += STORE::EXPIRY_SEC - 100
      keep = store.mint_or_get(chat_id: 222)
      current += 200 # 111 is now expired; 222 is still fresh

      assert_equal keep, store.mint_or_get(chat_id: 222), "the fresh code is reused"

      doc = JSON.parse(File.read(File.join(dir, STORE::FILENAME)))
      refute doc.key?(expiring), "reuse must persist the prune of the expired sibling"
      assert doc.key?(keep)
    end
  end

  def test_pending_is_sorted_by_created_at_and_excludes_expired
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      old = store.mint_or_get(chat_id: 111)
      current += 60
      middle = store.mint_or_get(chat_id: 222)
      current += 60
      newest = store.mint_or_get(chat_id: 333)

      current = Time.utc(2026, 6, 30, 12, 0, 0) + STORE::EXPIRY_SEC + 1

      assert_equal [ middle, newest ], store.pending.map(&:code)
      assert_equal [ 222, 333 ], store.pending.map(&:chat_id)
      refute_includes store.pending.map(&:code), old
    end
  end

  def test_missing_and_corrupt_files_are_treated_as_empty
    Dir.mktmpdir("hive-pairing-store") do |dir|
      store = STORE.new(state_home: dir)

      assert_empty store.pending
      File.write(File.join(dir, STORE::FILENAME), "{not json")

      assert_empty store.pending
      code = store.mint_or_get(chat_id: 111)
      assert_match(/\A[A-Z]{8}\z/, code)
      assert_equal [ 111 ], store.pending.map(&:chat_id)
    end
  end

  def test_strict_pending_distinguishes_a_corrupt_store_from_an_empty_one
    Dir.mktmpdir("hive-pairing-store") do |dir|
      store = STORE.new(state_home: dir)
      File.write(File.join(dir, STORE::FILENAME), "{not json")

      error = assert_raises(STORE::ReadError) { store.pending(strict: true) }

      assert_match(/is unreadable/, error.message)
    end
  end

  def test_non_object_store_is_treated_as_unreadable
    Dir.mktmpdir("hive-pairing-store") do |dir|
      store = STORE.new(state_home: dir)
      File.write(File.join(dir, STORE::FILENAME), "[]")

      assert_empty store.pending
      assert_raises(STORE::ReadError) { store.pending(strict: true) }
    end
  end

  def test_pending_treats_file_vanishing_mid_read_as_empty
    Dir.mktmpdir("hive-pairing-store") do |dir|
      store = STORE.new(state_home: dir, now: -> { Time.utc(2026, 6, 30, 12, 0, 0) })
      store.mint_or_get(chat_id: 111)
      path = File.join(dir, STORE::FILENAME)

      # The TOCTOU race: the file passes File.exist? but is unlinked before
      # File.read runs, so read raises ENOENT. pending must degrade to empty,
      # not crash. (minitest/mock is not bundled — override File.read for this
      # path and restore it after.)
      original_read = File.method(:read)
      File.define_singleton_method(:read) do |target, *rest, **opts|
        raise Errno::ENOENT, target if target == path

        original_read.call(target, *rest, **opts)
      end
      begin
        assert_empty store.pending
      ensure
        File.define_singleton_method(:read, original_read)
      end
    end
  end

  def test_invalid_created_at_payload_is_ignored
    Dir.mktmpdir("hive-pairing-store") do |dir|
      File.write(File.join(dir, STORE::FILENAME), JSON.generate(
                                                    "ABCDEFGH" => {
                                                      "chat_id" => 111,
                                                      "created_at" => "not-a-time"
                                                    }
                                                  ))
      store = STORE.new(state_home: dir)

      assert_empty store.pending
    end
  end

  def test_interleaved_writers_leave_valid_json
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      stores = [
        STORE.new(state_home: dir, now: -> { current }),
        STORE.new(state_home: dir, now: -> { current })
      ]

      threads = 10.times.map do |idx|
        Thread.new { stores[idx % 2].mint_or_get(chat_id: 10_000 + idx) }
      end
      codes = threads.map(&:value)

      doc = JSON.parse(File.read(File.join(dir, STORE::FILENAME)))
      assert_equal 10, doc.length
      assert_equal 10, codes.uniq.length
      assert_equal codes.sort, doc.keys.sort
      assert_equal (10_000..10_009).to_a.sort, doc.values.map { |payload| payload.fetch("chat_id") }.sort
    end
  end
end
