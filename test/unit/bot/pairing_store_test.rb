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

  def test_resolve_and_consume_returns_chat_id_and_removes_only_that_entry
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      first = store.mint_or_get(chat_id: 111)
      second = store.mint_or_get(chat_id: 222)

      assert_equal 111, store.resolve_and_consume(code: first)
      assert_equal :unknown, store.resolve_and_consume(code: first)
      assert_equal [ second ], store.pending.map(&:code)
      assert_equal 222, store.pending.first.chat_id
    end
  end

  def test_resolve_and_consume_distinguishes_expired_from_unknown
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      code = store.mint_or_get(chat_id: 111)

      current += STORE::EXPIRY_SEC + 1

      assert_equal :expired, store.resolve_and_consume(code: code)
      assert_equal :unknown, store.resolve_and_consume(code: code)
      assert_empty store.pending
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

  def test_prune_expired_returns_removed_count
    Dir.mktmpdir("hive-pairing-store") do |dir|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      store = STORE.new(state_home: dir, now: -> { current })
      store.mint_or_get(chat_id: 111)
      current += STORE::EXPIRY_SEC + 1

      assert_equal 1, store.prune_expired!
      assert_equal 0, store.prune_expired!
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
