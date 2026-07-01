require "test_helper"
require "json"
require "tmpdir"
require "hive/bot/pairing_approval_queue"

class HiveBotPairingApprovalQueueTest < Minitest::Test
  Q = Hive::Bot::PairingApprovalQueue

  def test_write_then_pending_roundtrip
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      Q.write!(chat_id: 42, state_home: dir, now: Time.utc(2026, 6, 30, 18, 14, 2))

      pending = Q.pending(state_home: dir)
      assert_equal 1, pending.size
      notice = pending.first
      assert_equal 42, notice.chat_id
      assert_equal Time.utc(2026, 6, 30, 18, 14, 2), notice.created_at
      assert_match(/\A[0-9a-f]{16}\z/, notice.notice_id)
    end
  end

  def test_directory_is_owner_only
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      qdir = Q.directory(state_home: dir)

      assert_equal 0o700, File.stat(qdir).mode & 0o777
    end
  end

  def test_pending_sorted_by_created_at
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      Q.write!(chat_id: 2, state_home: dir, now: Time.utc(2026, 6, 30, 18, 14, 9))
      Q.write!(chat_id: 1, state_home: dir, now: Time.utc(2026, 6, 30, 18, 11, 0))

      assert_equal [ 1, 2 ], Q.pending(state_home: dir).map(&:chat_id)
    end
  end

  def test_remove_is_idempotent
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      notice_id = Q.write!(chat_id: 42, state_home: dir)

      assert Q.remove(notice_id, state_home: dir)
      refute Q.remove(notice_id, state_home: dir)
      assert_empty Q.pending(state_home: dir)
    end
  end

  def test_pending_routes_malformed_to_bad_handler
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      bad_path = File.join(Q.directory(state_home: dir), "20260630-bad.json")
      File.write(bad_path, "{not json")
      seen = []

      pending = Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { seen << [ path, reason ] })

      assert_empty pending
      assert_equal [ [ bad_path, "malformed_json" ] ], seen
      assert File.exist?(bad_path), "pending must not delete; the consumer decides"
    end
  end

  def test_pending_leaves_transiently_unreadable_notice_for_retry
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      Q.write!(chat_id: 42, state_home: dir)
      path = Dir.glob(File.join(dir, Q::DIRNAME, "*.json")).first
      routed = []

      # A structurally-valid notice hit by a transient read fault (EACCES) must
      # NOT be folded into corruption: it is neither returned this tick nor
      # handed to bad_handler (whose drain deletes), so it survives for a retry.
      with_file_read_raising(Errno::EACCES) do
        assert_empty Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { routed << reason }),
                     "an unreadable notice is not returned this tick"
      end

      assert_empty routed,
                   "a transient read fault must not be routed to bad_handler (which would delete owner state)"
      assert File.exist?(path), "the notice must be left on disk for a later tick"
    end
  end

  def test_expired_false_for_invalid_notice
    refute Q.expired?(Object.new)
    refute Q.expired?(Q::Notice.new(notice_id: "n", created_at: nil, chat_id: 1, path: nil))
  end

  def test_remove_skips_malformed_file_matching_id
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      File.write(File.join(Q.directory(state_home: dir), "20260630-rmbad001.json"), "{not json")

      refute Q.remove("rmbad001", state_home: dir)
      assert File.exist?(File.join(Q.directory(state_home: dir), "20260630-rmbad001.json"))
    end
  end

  def test_remove_tolerates_file_disappearing_after_parse
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      notice_id = Q.write!(chat_id: 42, state_home: dir)

      with_file_unlink_raising(Errno::ENOENT) do
        refute Q.remove(notice_id, state_home: dir)
      end
    end
  end

  def test_pending_rejects_invalid_created_at
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      bad_path = File.join(Q.directory(state_home: dir), "20260630-bad-time.json")
      File.write(bad_path, JSON.generate(
                             "schema" => Q::SCHEMA,
                             "schema_version" => Q::SCHEMA_VERSION,
                             "notice_id" => "notice",
                             "created_at" => "not-a-time",
                             "chat_id" => 42
                           ))
      seen = []

      assert_empty Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { seen << [ path, reason ] })
      assert_equal [ [ bad_path, "invalid_created_at" ] ], seen
    end
  end

  def test_written_notice_is_valid_json
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      Q.write!(chat_id: 42, state_home: dir)
      path = Dir.glob(File.join(dir, Q::DIRNAME, "*.json")).first

      doc = JSON.parse(File.read(path))

      assert_equal Q::SCHEMA, doc.fetch("schema")
      assert_equal Q::SCHEMA_VERSION, doc.fetch("schema_version")
      assert_equal 42, doc.fetch("chat_id")
    end
  end

  def test_remove_uses_known_path_for_direct_unlink
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      Q.write!(chat_id: 42, state_home: dir)
      notice = Q.pending(state_home: dir).first

      assert Q.remove(notice.notice_id, state_home: dir, path: notice.path)
      assert_empty Q.pending(state_home: dir)
    end
  end

  def test_remove_known_path_returns_false_when_file_absent
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      refute Q.remove("deadbeef", state_home: dir, path: File.join(dir, "gone.json"))
    end
  end

  def test_remove_known_path_refuses_mismatched_notice_id
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      Q.write!(chat_id: 42, state_home: dir)
      notice = Q.pending(state_home: dir).first

      refute Q.remove("not-this-notice", state_home: dir, path: notice.path)
      assert_equal 1, Q.pending(state_home: dir).size, "a mismatched id must not delete the file"
    end
  end

  def test_remove_known_path_skips_malformed_file
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      bad = File.join(Q.directory(state_home: dir), "20260630-bad.json")
      File.write(bad, "{not json")

      refute Q.remove("whatever", state_home: dir, path: bad)
      assert File.exist?(bad)
    end
  end

  def test_remove_known_path_tolerates_file_disappearing_after_parse
    Dir.mktmpdir("hive-pairing-approval") do |dir|
      Q.write!(chat_id: 42, state_home: dir)
      notice = Q.pending(state_home: dir).first

      with_file_unlink_raising(Errno::ENOENT) do
        refute Q.remove(notice.notice_id, state_home: dir, path: notice.path)
      end
    end
  end

  def test_expired_uses_a_strict_greater_than_boundary
    created = Time.utc(2026, 6, 30, 12, 0, 0)
    notice = Q::Notice.new(notice_id: "n", created_at: created, chat_id: 1, path: nil)

    refute Q.expired?(notice, now: created + Q::EXPIRY_SEC),
           "a notice exactly at the expiry age is not yet expired"
    assert Q.expired?(notice, now: created + Q::EXPIRY_SEC + 1),
           "one second past the expiry age is expired"
  end

  private

  def with_file_unlink_raising(error_class)
    singleton = class << File; self; end
    singleton.alias_method :hive_original_unlink, :unlink
    singleton.define_method(:unlink) { |_path| raise error_class }
    yield
  ensure
    singleton&.alias_method(:unlink, :hive_original_unlink)
    singleton&.remove_method(:hive_original_unlink)
  end

  def with_file_read_raising(error_class)
    singleton = class << File; self; end
    singleton.alias_method :hive_original_read, :read
    singleton.define_method(:read) { |*_args| raise error_class }
    yield
  ensure
    singleton&.alias_method(:read, :hive_original_read)
    singleton&.remove_method(:hive_original_read)
  end
end
