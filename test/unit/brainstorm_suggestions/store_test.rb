require "test_helper"
require "hive/brainstorm_suggestions/store"

class HiveBrainstormSuggestionsStoreTest < Minitest::Test
  def record
    {
      "question_id" => "round-1-q1",
      "ordinal" => 1,
      "input_binding" => "a" * 64,
      "suggestion_binding" => "b" * 64,
      "state" => "fresh",
      "text" => "Prefer the tracked implementation.",
      "rationale" => "It matches the existing adapter boundary.",
      "provenance" => [ "repository" ],
      "safe_reason" => nil,
      "retryable" => true,
      "dismissed" => false,
      "attempt_id" => "attempt-1"
    }
  end

  def test_owner_private_round_trip_contains_only_validated_state
    Dir.mktmpdir do |root|
      store = Hive::BrainstormSuggestions::Store.new(root)
      store.write("task_generation" => "generation-1", "records" => [ record ])

      document = store.read

      assert_equal "fresh", document.fetch("records").first.fetch("state")
      assert_equal 0o600, File.stat(store.path).mode & 0o777
      refute_includes File.read(store.path), "raw_context"
    end
  end

  def test_malformed_or_unsafe_sidecar_never_exposes_candidate_text
    Dir.mktmpdir do |root|
      path = File.join(root, Hive::BrainstormSuggestions::Store::FILENAME)
      File.write(path, "{malformed", mode: "w", perm: 0o600)
      malformed = Hive::BrainstormSuggestions::Store.new(root).read
      assert_equal true, malformed.fetch("corrupt")
      assert_empty malformed.fetch("records")

      File.delete(path)
      File.symlink("elsewhere", path)
      unsafe = Hive::BrainstormSuggestions::Store.new(root).read
      assert_equal true, unsafe.fetch("corrupt")
      assert_empty unsafe.fetch("records")
    end
  end

  def test_rejects_raw_context_unknown_fields_and_invalid_fresh_records
    Dir.mktmpdir do |root|
      store = Hive::BrainstormSuggestions::Store.new(root)

      assert_raises(Hive::BrainstormSuggestions::InvalidState) do
        store.write("records" => [ record.merge("raw_context" => "secret") ])
      end
      assert_raises(Hive::BrainstormSuggestions::InvalidState) do
        store.write("records" => [ record.merge("rationale" => "") ])
      end
    end
  end
end
