require "test_helper"
require "fileutils"
require "json"
require "json_schemer"
require "tmpdir"
require "hive/daemon/dispatch_result_queue"

# ADV-1: pins the daemon→bot failure-notice channel.
class HiveDaemonDispatchResultQueueTest < Minitest::Test
  include HiveTestHelper

  Q = Hive::Daemon::DispatchResultQueue

  def test_write_then_pending_roundtrip
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      Q.write!(chat_id: 42, update_id: 7, project: "hive", slug: "my-task",
               request_id: "req12345", exit_code: 4,
               command: "hive markers clear my-task", state_home: dir,
               now: Time.utc(2026, 5, 28, 18, 14, 2))

      pending = Q.pending(state_home: dir)
      assert_equal 1, pending.size
      notice = pending.first
      assert_equal 42, notice.chat_id
      assert_equal "my-task", notice.slug
      assert_equal 4, notice.exit_code
      assert_equal "req12345", notice.request_id
    end
  end

  def test_pending_sorted_by_created_at
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      Q.write!(chat_id: 1, project: "p", slug: "second", request_id: "r2",
               exit_code: 1, command: "hive review second", state_home: dir,
               now: Time.utc(2026, 5, 28, 18, 14, 9))
      Q.write!(chat_id: 1, project: "p", slug: "first", request_id: "r1",
               exit_code: 1, command: "hive review first", state_home: dir,
               now: Time.utc(2026, 5, 28, 18, 11, 0))
      assert_equal %w[first second], Q.pending(state_home: dir).map(&:slug)
    end
  end

  def test_remove_is_idempotent
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      result_id = Q.write!(chat_id: 1, project: "p", slug: "s", request_id: "r",
                           exit_code: 2, command: "hive develop s", state_home: dir)
      assert Q.remove(result_id, state_home: dir)
      refute Q.remove(result_id, state_home: dir), "second remove is a no-op"
      assert_empty Q.pending(state_home: dir)
    end
  end

  def test_pending_routes_malformed_to_bad_handler
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      bad_path = File.join(Q.directory(state_home: dir), "20260528-bad.json")
      File.write(bad_path, "{not json")
      seen = []
      pending = Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { seen << reason })
      assert_empty pending
      assert_equal [ "malformed_json" ], seen
      assert File.exist?(bad_path), "pending must not delete; the consumer decides"
    end
  end

  def test_pending_rejects_unparseable_created_at
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      qdir = Q.directory(state_home: dir)
      payload = {
        "schema" => "hive-dispatch-result", "schema_version" => 1,
        "result_id" => "abcd1234", "created_at" => "not-a-time",
        "chat_id" => 1, "project" => "p", "slug" => "s",
        "request_id" => "r", "exit_code" => 1, "command" => "hive review s"
      }
      File.write(File.join(qdir, "20260528-abcd1234.json"), JSON.generate(payload))
      reasons = []
      assert_empty Q.pending(state_home: dir, bad_handler: ->(path:, reason:) { reasons << reason })
      assert_equal [ "invalid_created_at" ], reasons
    end
  end

  def test_remove_skips_file_whose_result_id_differs
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      qdir = Q.directory(state_home: dir)
      # File NAME contains the target id, but body result_id differs.
      payload = {
        "schema" => "hive-dispatch-result", "schema_version" => 1,
        "result_id" => "other999", "created_at" => Time.now.utc.iso8601,
        "chat_id" => 1, "project" => "p", "slug" => "s",
        "request_id" => "r", "exit_code" => 1, "command" => "hive review s"
      }
      File.write(File.join(qdir, "20260528-target01.json"), JSON.generate(payload))
      refute Q.remove("target01", state_home: dir), "must not remove a file whose body id differs"
      assert_equal 1, Dir.glob(File.join(qdir, "*.json")).length
    end
  end

  def test_remove_skips_malformed_file_matching_id
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      qdir = Q.directory(state_home: dir)
      # File NAME contains the id but body is unparseable → remove skips
      # it (rescue → next) and reports false.
      File.write(File.join(qdir, "20260528-rmbad001.json"), "{not json")
      refute Q.remove("rmbad001", state_home: dir)
      assert File.exist?(File.join(qdir, "20260528-rmbad001.json"))
    end
  end

  def test_remove_returns_false_on_directory_enoent
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      with_replaced_singleton_method(Dir, :glob, ->(*) { raise Errno::ENOENT, "vanished" }) do
        refute Q.remove("anything", state_home: dir)
      end
    end
  end

  def test_written_notice_validates_against_published_schema
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      Q.write!(chat_id: 42, update_id: 7, project: "hive", slug: "my-task",
               request_id: "abcd1234", exit_code: 4,
               command: "hive markers clear my-task", state_home: dir)
      path = Dir.glob(File.join(dir, "dispatch_results", "*.json")).first
      doc = JSON.parse(File.read(path))

      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-dispatch-result"))))
      errors = schemer.validate(doc).to_a
      assert_empty errors, "written notice must conform to hive-dispatch-result.v1.json: #{errors.inspect}"
    end
  end
end
