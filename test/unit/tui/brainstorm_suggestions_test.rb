# frozen_string_literal: true

require "test_helper"
require "hive/tui/brainstorm_suggestions"

class HiveTuiBrainstormSuggestionsTest < Minitest::Test
  include HiveTestHelper

  def test_projection_is_parser_inert_and_untouched_envelope_preserves_candidate
    with_task do |task, path, store|
      lease = Hive::Tui::BrainstormSuggestions.project!(task_root: task, path: path)

      assert_equal 1, lease.regions.length
      assert_includes File.read(path), lease.regions.first.source
      assert_nil Hive::BrainstormParser.parse(path).first.answer

      result = Hive::Tui::BrainstormSuggestions.reconcile_editor_exit!(
        task_root: task, path: path, lease: lease
      )
      assert_equal 1, result.untouched
      assert_equal "fresh", store.read.dig("records", 0, "state")
      refute store.read.dig("records", 0, "dismissed")
    end
  end

  def test_removing_only_delimiters_adopts_byte_identical_body_and_deletes_record
    with_task do |task, path, store|
      lease = Hive::Tui::BrainstormSuggestions.project!(task_root: task, path: path)
      region = lease.regions.first
      adopted = region.source
                        .sub(/\A<!-- hive-suggestion:v1[^\n]* -->\n/, "")
                        .sub(/<!-- \/hive-suggestion:v1 -->\n\z/, "")
      File.write(path, File.read(path).sub(region.source, adopted))

      result = Hive::Tui::BrainstormSuggestions.reconcile_editor_exit!(
        task_root: task, path: path, lease: lease
      )

      assert_equal 1, result.adopted
      assert_equal region.text, Hive::BrainstormParser.parse(path).first.answer
      refute File.exist?(store.path)
      refute_includes File.read(path), "hive-suggestion:v1"
    end
  end

  def test_deleting_exact_envelope_dismisses_and_restore_reprojects_it
    with_task do |task, path, store|
      lease = Hive::Tui::BrainstormSuggestions.project!(task_root: task, path: path)
      File.write(path, File.read(path).sub(lease.regions.first.source, ""))

      result = Hive::Tui::BrainstormSuggestions.reconcile_editor_exit!(
        task_root: task, path: path, lease: lease
      )
      assert_equal 1, result.dismissed
      assert store.read.dig("records", 0, "dismissed")
      assert_nil Hive::BrainstormParser.parse(path).first.answer

      restored = Hive::Tui::BrainstormSuggestions.restore!(task)
      assert_equal "updated", restored.fetch("status")
      refute store.read.dig("records", 0, "dismissed")
      second = Hive::Tui::BrainstormSuggestions.project!(task_root: task, path: path)
      assert_includes File.read(path), second.regions.first.source
    end
  end

  def test_newer_sidecar_candidate_is_never_inserted_into_old_saved_buffer
    with_task do |task, path, store|
      lease = Hive::Tui::BrainstormSuggestions.project!(task_root: task, path: path)
      old_source = lease.regions.first.source
      document = store.read
      newer = document.fetch("records").first
      newer["suggestion_binding"] = "c" * 64
      newer["text"] = "Newer sidecar-only candidate"
      store.write(document)

      result = Hive::Tui::BrainstormSuggestions.reconcile_editor_exit!(
        task_root: task, path: path, lease: lease
      )

      assert_equal 1, result.stale
      refute_includes File.read(path), old_source
      refute_includes File.read(path), "Newer sidecar-only candidate"
      assert_equal "c" * 64, store.read.dig("records", 0, "suggestion_binding")
      assert_nil Hive::BrainstormParser.parse(path).first.answer
    end
  end

  def test_retry_clears_actionable_text_without_writing_an_answer
    with_task do |task, path, store|
      before = Hive::BrainstormParser.parse(path).map(&:answer)

      receipt = Hive::Tui::BrainstormSuggestions.retry!(task)
      record = store.read.fetch("records").first

      assert_equal "updated", receipt.fetch("status")
      assert_equal "stale", record.fetch("state")
      assert_nil record.fetch("text")
      assert_equal before, Hive::BrainstormParser.parse(path).map(&:answer)
    end
  end

  def test_projection_and_reconciliation_fail_closed_when_state_becomes_unsafe
    with_task do |task, path, _store|
      lease = Hive::Tui::BrainstormSuggestions.project!(task_root: task, path: path)

      replacement = ->(*) { raise Hive::BrainstormSuggestions::UnsafePath, "unsafe" }
      with_replaced_singleton_method(
        Hive::BrainstormSuggestions::Store, :new, replacement
      ) do
        empty = Hive::Tui::BrainstormSuggestions.project!(task_root: task, path: path)
        assert_empty empty.regions

        result = Hive::Tui::BrainstormSuggestions.reconcile_editor_exit!(
          task_root: task, path: path, lease: lease
        )
        assert_equal 0, result.adopted
        assert_equal "unavailable", Hive::Tui::BrainstormSuggestions.restore!(task).fetch("status")
      end
    end
  end

  def test_projection_adds_a_newline_before_an_envelope_when_heading_lacks_one
    question = "Question?"
    record = fresh_record(question)
    projected, regions = Hive::Tui::BrainstormSuggestions.send(
      :insert_records, "### Q1. #{question}\n### A1.", [ record ]
    )

    assert_equal 1, regions.length
    assert_includes projected, "### A1.\n<!-- hive-suggestion:v1"
  end

  def test_invalid_projection_path_is_inert
    bad_path = Object.new
    bad_path.define_singleton_method(:to_s) { raise ArgumentError, "bad path" }

    refute Hive::Tui::BrainstormSuggestions.send(
      :brainstorm_path?, "/tmp/task", bad_path
    )
  end

  private

  def with_task
    Dir.mktmpdir do |root|
      task = File.join(root, "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      path = File.join(task, "brainstorm.md")
      question = "Which scheduler seam?"
      File.write(
        path,
        "## Round 1\n\n### Q1. #{question}\n### A1.\n\n<!-- WAITING -->\n"
      )
      store = Hive::BrainstormSuggestions::Store.new(task)
      store.write("records" => [ fresh_record(question) ])
      yield task, path, store
    end
  end

  def fresh_record(question)
    {
      "question_id" => "question-1",
      "ordinal" => 1,
      "round" => 1,
      "question_number" => 1,
      "question_fingerprint" => Hive::BrainstormParser.question_fingerprint(question),
      "input_binding" => "a" * 64,
      "suggestion_binding" => "b" * 64,
      "state" => "fresh",
      "text" => "Use the daemon scheduler seam.",
      "rationale" => "It already owns polling.",
      "provenance" => [ "repository" ],
      "safe_reason" => nil,
      "retryable" => true,
      "dismissed" => false,
      "attempt_id" => "attempt-1",
      "candidate_id" => "candidate-1",
      "requested_at" => "2026-08-30T12:00:00Z",
      "updated_at" => "2026-08-30T12:00:00Z",
      "next_retry_at" => nil,
      "automatic_attempts" => 1,
      "input_epoch" => "a" * 64,
      "error_code" => nil
    }
  end
end
