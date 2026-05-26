require "test_helper"
require "hive/bot/alert_store"
require "hive/bot/status_watcher"

class HiveBotAlertStoreTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  def row(attrs: { "pass" => "1" }, action: "recover_review", project: "hive",
          slug: "stuck-task-260525-abcd", stage: "6-review")
    Row.new(
      project: project,
      slug: slug,
      stage: stage,
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

  def test_shape_invalid_entries_are_treated_as_corrupt
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      File.write(path, JSON.generate({ "schema_version" => 1, "entries" => { "fp1" => 1 } }))
      logger = StubLogger.new

      store = Hive::Bot::AlertStore.new(path: path, logger: logger)

      assert_equal [], store.each_fingerprint.to_a
      refute File.exist?(path)
      assert Dir.glob("#{path}.corrupt-*").any?
      assert_equal :alert_store_corrupt, logger.events.last.first
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

  def test_remove_matching_removes_matching_rows_only
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      store.add("fp1", row(slug: "target-task-260525-abcd", stage: "6-review"), Time.utc(2026, 5, 25, 10, 0, 0))
      store.add("fp2", row(slug: "target-task-260525-abcd", stage: "5-open-pr"), Time.utc(2026, 5, 25, 10, 0, 0))
      store.add("fp3", row(slug: "other-task-260525-abcd", stage: "6-review"), Time.utc(2026, 5, 25, 10, 0, 0))

      removed = store.remove_matching(project: "hive", slug: "target-task-260525-abcd", stage: "6-review")

      assert_equal 1, removed
      assert_nil store.entry("fp1")
      assert_equal "target-task-260525-abcd", store.entry("fp2").row.slug
      assert_equal "other-task-260525-abcd", store.entry("fp3").row.slug
    end
  end

  def test_add_persists_delivered_to_chat_ids
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      Hive::Bot::AlertStore.new(path: path).add(
        "fp1", row, Time.utc(2026, 5, 25, 10, 0, 0), delivered_to: [ 12345, 67890 ]
      )

      reopened = Hive::Bot::AlertStore.new(path: path)
      assert_equal [ "12345", "67890" ], reopened.entry("fp1").delivered_to
    end
  end

  def test_record_delivery_appends_new_chat_ids_only
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      store.add("fp1", row, Time.utc(2026, 5, 25, 10, 0, 0), delivered_to: [ 12345 ])

      assert store.record_delivery("fp1", [ 67890 ]),
             "record_delivery must return true when chat is newly added"
      assert_equal [ "12345", "67890" ], store.entry("fp1").delivered_to

      refute store.record_delivery("fp1", [ 12345, 67890 ]),
             "record_delivery must return false when all chats already delivered"
    end
  end

  def test_record_delivery_on_missing_fingerprint_returns_false
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))

      refute store.record_delivery("missing", [ 12345 ])
    end
  end

  def test_clean_orphaned_tmp_files_swallows_glob_errors
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      original_glob = Dir.method(:glob)
      Dir.define_singleton_method(:glob) do |*args, **opts|
        raise IOError, "synthetic glob failure" if args.first.to_s.include?(File.dirname(path))

        original_glob.call(*args, **opts)
      end
      Hive::Bot::AlertStore.new(path: path) # must NOT raise — cleanup is best-effort
    ensure
      Dir.define_singleton_method(:glob, original_glob) if original_glob
    end
  end

  def test_parse_time_returns_nil_for_malformed_persisted_value
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      File.write(path, JSON.generate({
                                       "schema_version" => 1,
                                       "entries" => {
                                         "fp1" => {
                                           "first_seen_at" => "not-a-real-time",
                                           "reminded_at" => nil,
                                           "row" => {
                                             "project" => "hive", "slug" => "a-260525-aaaa", "stage" => "6-review",
                                             "marker" => "review_error", "attrs" => {}, "action" => "recover_review"
                                           }
                                         }
                                       }
                                     }))
      store = Hive::Bot::AlertStore.new(path: path)

      assert_nil store.entry("fp1").first_seen_at,
                 "malformed first_seen_at must parse to nil rather than raising"
    end
  end

  def test_constructor_cleans_orphan_tmp_files
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      orphan = File.join(dir, ".alerts.json.99999.deadbeef.tmp")
      File.write(orphan, "garbage")
      File.write(path, JSON.generate({ "schema_version" => 1, "entries" => {} }))

      Hive::Bot::AlertStore.new(path: path)

      refute File.exist?(orphan), "orphan tmp file must be cleaned up at construction"
      assert File.exist?(path), "live alert state file must NOT be touched"
    end
  end

  def test_corrupt_rename_failure_starts_empty_without_raising
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      # Write a corrupt file then make the parent dir read-only so File.rename
      # inside handle_corrupt! raises a SystemCallError.
      File.write(path, "not json")
      File.chmod(0o500, dir)
      logger = StubLogger.new

      store = Hive::Bot::AlertStore.new(path: path, logger: logger)

      assert_equal [], store.each_fingerprint.to_a, "store must start empty when rename fails"
      event = logger.events.find { |e| e.first == :alert_store_corrupt }
      refute_nil event
      assert_nil event.last[:corrupt_path],
                 "corrupt_path must be nil when File.rename could not move the bad file aside"
    ensure
      File.chmod(0o700, dir) if dir && File.directory?(dir)
    end
  end

  def test_concurrent_contention_on_same_fingerprint_preserves_valid_json
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      store = Hive::Bot::AlertStore.new(path: path)
      now = Time.utc(2026, 5, 25, 10, 0, 0)
      fingerprint = "shared-fp"

      threads = 20.times.map do |i|
        Thread.new do
          if i.even?
            store.add(fingerprint, row(attrs: { "pass" => i.to_s }), now + i)
          else
            store.remove(fingerprint)
          end
        end
      end
      threads.each(&:join)

      # Final state is unspecified (race), but the on-disk JSON must always
      # be parseable — every persist_locked! is atomic.
      content = File.read(path)
      assert_kind_of Hash, JSON.parse(content),
                     "on-disk file must remain parseable JSON under contention"
    end
  end

  def test_persist_failure_rolls_back_in_memory_state_on_add
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      # Add one entry successfully so we have a baseline.
      store.add("fp1", row, Time.utc(2026, 5, 25, 10, 0, 0))
      assert_equal [ "fp1" ], store.each_fingerprint.to_a

      # Force the next persist to fail.
      store.define_singleton_method(:persist_locked!) { raise IOError, "disk full" }
      assert_raises(IOError) do
        store.add("fp2", row, Time.utc(2026, 5, 25, 10, 0, 5))
      end

      # In-memory state must NOT contain fp2 — otherwise a restart would
      # re-alert anything persisted only in memory.
      assert_equal [ "fp1" ], store.each_fingerprint.to_a,
                   "failed persist must roll back the in-memory mutation"
    end
  end

  def test_persist_failure_rolls_back_remove_matching
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      store.add("fp1", row, Time.utc(2026, 5, 25, 10, 0, 0))
      store.add("fp2", row(slug: "other-task-260525-abcd"), Time.utc(2026, 5, 25, 10, 0, 5))

      store.define_singleton_method(:persist_locked!) { raise IOError, "disk full" }
      assert_raises(IOError) do
        store.remove_matching(project: "hive", slug: "stuck-task-260525-abcd", stage: "6-review")
      end

      assert_includes store.each_fingerprint.to_a, "fp1",
                      "remove_matching must roll back deletions on persist failure"
      assert_includes store.each_fingerprint.to_a, "fp2"
    end
  end

  def test_remove_matching_with_marker_only_removes_matching_marker
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      now = Time.utc(2026, 5, 25, 10, 0, 0)
      store.add("fp1", row(slug: "task", stage: "6-review", attrs: { "pass" => "2" }), now)
      store.add(
        "fp2",
        Row.new(project: "hive", slug: "task", stage: "6-review", marker: "review_ci_stale",
                attrs: { "pass" => "2" }, action: "recover_review"),
        now
      )

      removed = store.remove_matching(project: "hive", slug: "task", stage: "6-review", marker: "review_error")

      assert_equal 1, removed, "only the review_error fingerprint should have been removed"
      assert_nil store.entry("fp1"), "review_error entry must be cleared"
      refute_nil store.entry("fp2"), "review_ci_stale entry must remain — different marker, different fingerprint"
    end
  end

  def test_remove_matching_with_match_attr_only_removes_matching_attr
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      now = Time.utc(2026, 5, 25, 10, 0, 0)
      store.add("fp1", row(attrs: { "pass" => "2", "phase" => "fix" }), now)
      store.add("fp2", row(attrs: { "pass" => "3", "phase" => "fix" }), now)

      removed = store.remove_matching(project: "hive", slug: "stuck-task-260525-abcd", stage: "6-review",
                                       marker: "review_error", match_attr: "pass=2")

      assert_equal 1, removed, "only the pass=2 entry should be removed"
      assert_nil store.entry("fp1")
      refute_nil store.entry("fp2"), "pass=3 entry remains because the match_attr differs"
    end
  end

  def test_remove_matching_with_no_marker_filter_still_removes_all_for_tuple
    # Backward compat: callers that pass project/slug/stage but no marker
    # should keep the old broad-delete behaviour.
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      now = Time.utc(2026, 5, 25, 10, 0, 0)
      store.add("fp1", row(attrs: { "pass" => "2" }), now)
      store.add(
        "fp2",
        Row.new(project: "hive", slug: "stuck-task-260525-abcd", stage: "6-review", marker: "review_ci_stale",
                attrs: {}, action: "recover_review"),
        now
      )

      removed = store.remove_matching(project: "hive", slug: "stuck-task-260525-abcd", stage: "6-review")

      assert_equal 2, removed
    end
  end

  def test_record_send_failure_sets_exponential_backoff
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      now = Time.utc(2026, 5, 25, 10, 0, 0)
      store.add("fp1", row, now)

      store.record_send_failure("fp1", now)
      assert_equal 1, store.entry("fp1").consecutive_failures
      assert_equal now + 60, store.entry("fp1").next_attempt_after

      store.record_send_failure("fp1", now)
      assert_equal 2, store.entry("fp1").consecutive_failures
      assert_equal now + 120, store.entry("fp1").next_attempt_after

      4.times { store.record_send_failure("fp1", now) }
      assert_equal 6, store.entry("fp1").consecutive_failures
      assert_equal now + 1800, store.entry("fp1").next_attempt_after, "backoff must cap at 1800s"
    end
  end

  def test_record_send_success_resets_failures_and_backoff
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      now = Time.utc(2026, 5, 25, 10, 0, 0)
      store.add("fp1", row, now)
      store.record_send_failure("fp1", now)
      assert_equal 1, store.entry("fp1").consecutive_failures

      assert store.record_send_success("fp1"),
             "record_send_success must return true when state was reset"
      assert_equal 0, store.entry("fp1").consecutive_failures
      assert_nil store.entry("fp1").next_attempt_after

      refute store.record_send_success("fp1"),
             "record_send_success must return false when there is nothing to reset"
    end
  end

  def test_record_delivery_resets_failures_and_backoff
    with_tmp_dir do |dir|
      store = Hive::Bot::AlertStore.new(path: File.join(dir, "alerts.json"))
      now = Time.utc(2026, 5, 25, 10, 0, 0)
      store.add("fp1", row, now, delivered_to: [ 12345 ])
      store.record_send_failure("fp1", now)
      assert_equal 1, store.entry("fp1").consecutive_failures

      store.record_delivery("fp1", [ 67890 ])

      assert_equal 0, store.entry("fp1").consecutive_failures,
                   "successful delivery must reset the failure counter"
      assert_nil store.entry("fp1").next_attempt_after
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
