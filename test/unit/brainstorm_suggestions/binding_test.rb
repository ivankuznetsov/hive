require "test_helper"
require "hive/brainstorm_suggestions/binding"

class HiveBrainstormSuggestionsBindingTest < Minitest::Test
  def test_input_binding_uses_only_selected_manifest_identity
    attributes = {
      task_incarnation: "task-1",
      task_generation: 3,
      brainstorm_generation: "brainstorm-7",
      question_identity: "round-2-q1",
      question_text: "Which adapter should we use?",
      manifest: {
        "recipe" => "tracked-relevance",
        "recipe_version" => 1,
        "entries" => [
          { "path" => "lib/adapter.rb", "mode" => "100644", "digest" => "a" * 64,
            "source" => "repository" }
        ],
        "diagnostics" => { "head" => "1" * 40 }
      },
      settled_answers: [ { "question" => "Earlier?", "answer" => "Yes" } ]
    }

    first = Hive::BrainstormSuggestions::Binding.input(**attributes)
    attributes[:manifest]["diagnostics"]["head"] = "2" * 40
    second = Hive::BrainstormSuggestions::Binding.input(**attributes)

    assert_equal first, second, "repository-global HEAD is diagnostic, not freshness authority"
    attributes[:manifest]["entries"][0]["digest"] = "b" * 64
    refute_equal first, Hive::BrainstormSuggestions::Binding.input(**attributes)
  end

  def test_suggestion_binding_adds_attempt_and_candidate_identity
    one = Hive::BrainstormSuggestions::Binding.suggestion(
      input_binding: "a" * 64, attempt_id: "attempt-1", candidate_id: "candidate-1"
    )
    two = Hive::BrainstormSuggestions::Binding.suggestion(
      input_binding: "a" * 64, attempt_id: "attempt-2", candidate_id: "candidate-1"
    )

    assert_match(/\A[0-9a-f]{64}\z/, one)
    refute_equal one, two
  end

  def test_symbol_manifest_keys_and_other_values_are_canonicalized
    custom = Object.new
    custom.define_singleton_method(:to_s) { "custom-value" }
    manifest = {
      recipe: "tracked-relevance",
      recipe_version: 1,
      entries: [ { path: "lib/example.rb", mode: "100644", digest: "a" * 64,
                   source: "repository" } ]
    }

    binding = Hive::BrainstormSuggestions::Binding.input(
      task_incarnation: "task", task_generation: 1, brainstorm_generation: custom,
      question_identity: "q1", question_text: "Question?", manifest: manifest,
      settled_answers: []
    )

    assert_match(/\A[0-9a-f]{64}\z/, binding)
    assert_match(/\A[0-9a-f]{64}\z/, Hive::BrainstormSuggestions::Binding.digest(custom))
  end
end
