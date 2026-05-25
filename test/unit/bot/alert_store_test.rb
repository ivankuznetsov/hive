require "test_helper"
require "hive/bot/alert_store"
require "hive/bot/status_watcher"

class HiveBotAlertStoreTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  def row(attrs: { "pass" => "1" }, action: "recover_review")
    Row.new(
      project: "hive",
      slug: "stuck-task-260525-abcd",
      stage: "6-review",
      marker: "review_error",
      attrs: attrs,
      action: action
    )
  end

  def test_initial_empty_store
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))

      assert_equal [], store.each_fingerprint.to_a
      assert_nil store.entry("missing")
    end
  end

  def test_add_reads_back_entry
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      now = Time.utc(2026, 5, 25, 10, 0, 0)

      store.add("fp1", row, now)

      assert_equal [ "fp1" ], store.each_fingerprint.to_a
      entry = store.entry("fp1")
      assert_equal now, entry.first_seen_at
      assert_nil entry.reminded_at
      assert_equal "hive", entry.row.project
      assert_equal({ "pass" => "1" }, entry.row.attrs)
    end
  end

  def test_persists_entries_across_instances
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      Hive::Bot::AlertStore.new(path: path).add("fp1", row, Time.utc(2026, 5, 25, 10, 0, 0))

      fresh = Hive::Bot::AlertStore.new(path: path)

      assert_equal [ "fp1" ], fresh.each_fingerprint.to_a
      assert_equal "stuck-task-260525-abcd", fresh.entry("fp1").row.slug
    end
  end

  def test_mark_reminded_and_remove
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      store.add("fp1", row, Time.utc(2026, 5, 25, 10, 0, 0))
      store.mark_reminded("fp1", Time.utc(2026, 5, 25, 18, 0, 0))

      assert_equal Time.utc(2026, 5, 25, 18, 0, 0), store.entry("fp1").reminded_at
      removed = store.remove("fp1")

      assert_equal "stuck-task-260525-abcd", removed.slug
      assert_nil store.entry("fp1")
    end
  end

  def test_corrupt_json_is_renamed_and_logged
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      File.write(path, "{")
      logger = StubLogger.new

      store = Hive::Bot::AlertStore.new(path: path, logger: logger)

      assert_equal [], store.each_fingerprint.to_a
      refute File.exist?(path)
      assert Dir.glob("#{path}.corrupt-*").any?
      event = logger.events.last
      assert_equal :alert_store_corrupt, event.first
      assert_equal path, event.last[:path]
    end
  end

  def test_schema_version_mismatch_is_treated_as_corrupt
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      File.write(path, JSON.generate({ "schema_version" => 2, "entries" => {} }))
      logger = StubLogger.new

      store = Hive::Bot::AlertStore.new(path: path, logger: logger)

      assert_equal [], store.each_fingerprint.to_a, "mismatched schema_version must yield empty store"
      refute File.exist?(path), "original file must be renamed away on schema mismatch"
      assert Dir.glob("#{path}.corrupt-*").any?, "corrupt-* sibling must exist after schema mismatch"
      event = logger.events.last
      assert_equal :alert_store_corrupt, event.first, "logger must receive :alert_store_corrupt event"
      assert_equal path, event.last[:path], ":path attribute must match the original file path"
    end
  end

  def test_unreadable_file_is_treated_as_corrupt
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      File.write(path, JSON.generate({ "schema_version" => 1, "entries" => {} }))
      File.chmod(0o000, path)
      logger = StubLogger.new

      store = Hive::Bot::AlertStore.new(path: path, logger: logger)

      assert_equal [], store.each_fingerprint.to_a, "unreadable file must yield empty store"
      event = logger.events.last
      assert_equal :alert_store_corrupt, event.first, "logger must receive :alert_store_corrupt event"
      assert_equal path, event.last[:path], ":path must match original file path"
    ensure
      File.chmod(0o644, path) if path && File.exist?(path)
    end
  end

  def test_concurrent_add_and_remove_smoke
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      threads = 10.times.map do |i|
        Thread.new do
          fingerprint = "fp#{i}"
          store.add(fingerprint, row(attrs: { "pass" => i.to_s }), Time.utc(2026, 5, 25, 10, 0, i))
          store.remove(fingerprint)
        end
      end
      threads.each(&:join)

      assert_equal [], store.each_fingerprint.to_a
    end
  end

  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end
end
