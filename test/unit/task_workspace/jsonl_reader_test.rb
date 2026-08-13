require "test_helper"
require "hive/task_workspace/jsonl_reader"

class TaskWorkspaceJsonlReaderTest < Minitest::Test
  include HiveTestHelper

  def test_pages_to_an_earlier_bounded_window_without_losing_records
    with_tmp_dir do |dir|
      path = File.join(dir, "events.jsonl")
      File.write(path, 20.times.map { |index| JSON.generate("id" => index, "body" => "x" * 30) }.join("\n") + "\n")
      reader = Hive::TaskWorkspace::JsonlReader.new(
        root: dir, reference: "events.jsonl", max_bytes: 250,
        max_records: 4, source: "event_stream"
      )

      first = reader.call
      second = reader.call(before: first.window_start)

      assert first.truncated
      assert second.truncated
      assert_operator second.records.last.fetch("id"), :<, first.records.first.fetch("id")
      assert_operator second.window_end, :<=, first.window_start
    end
  end

  def test_keeps_the_newest_complete_bounded_records_and_redacts_values
    with_tmp_dir do |root|
      rows = 8.times.map do |index|
        { "event_id" => "event-#{index}", "message" => "ghp_#{'a' * 36}" }
      end
      File.write(
        File.join(root, "events.jsonl"),
        rows.map { |row| JSON.generate(row) }.join("\n") + "\n"
      )

      result = Hive::TaskWorkspace::JsonlReader.new(
        root: root, reference: "events.jsonl", max_bytes: 300,
        max_records: 2, source: "event_stream"
      ).call

      assert_equal %w[event-6 event-7], result.records.map { |row| row.fetch("event_id") }
      refute_includes result.records.to_s, "ghp_"
      assert result.truncated
      assert_includes result.diagnostics.filter_map { |row| row.dig("details", "cap") },
                      "journal_suffix_bytes"
    end
  end

  def test_torn_malformed_and_symlinked_sources_degrade_without_raising
    with_tmp_dir do |root|
      File.write(
        File.join(root, "events.jsonl"),
        "#{JSON.generate('event_id' => 'ok')}\nnot-json\n{"
      )
      result = reader(root).call

      assert_equal [ "ok" ], result.records.map { |row| row.fetch("event_id") }
      assert result.truncated
      assert_includes result.diagnostics.map { |row| row.fetch("reason") },
                      "torn_trailing_record"
      assert_includes result.diagnostics.map { |row| row.fetch("reason") },
                      "malformed_record"

      File.rename(File.join(root, "events.jsonl"), File.join(root, "real.jsonl"))
      File.symlink(File.join(root, "real.jsonl"), File.join(root, "events.jsonl"))
      linked = reader(root).call
      assert_empty linked.records
      assert_equal "symlink_refused", linked.diagnostics.first.fetch("reason")
    end
  end

  private

  def reader(root)
    Hive::TaskWorkspace::JsonlReader.new(
      root: root, reference: "events.jsonl", max_bytes: 1024,
      max_records: 10, source: "event_stream"
    )
  end
end
