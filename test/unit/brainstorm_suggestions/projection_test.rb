require "test_helper"
require "hive/brainstorm_suggestions/projection"

class HiveBrainstormSuggestionsProjectionTest < Minitest::Test
  Question = Data.define(:text, :answer) do
    def answered? = !answer.nil?
  end

  def setup
    Hive::BrainstormSuggestions::Projection.clear_cache!
  end

  def teardown
    Hive::BrainstormSuggestions::Projection.clear_cache!
  end

  def test_missing_records_are_loading_without_observing_the_repository
    with_task do |root|
      calls = 0
      projection = build_projection(root, observer: lambda { |**|
        calls += 1
        flunk "a missing record must not scan repository context"
      })

      result = projection.call

      assert_equal 0, calls
      assert_equal %w[loading loading], result.values.map { |item| item.fetch("state") }
      assert result.values.all? { |item| item["text"].nil? && item["retryable"] == false }
    end
  end

  def test_two_current_records_share_one_observation_and_expose_only_fresh_text
    with_task do |root|
      records = [ fresh_record(1), failed_record(2) ]
      write_document(root, records)
      calls = 0
      observer = lambda do |records:, **|
        calls += 1
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: records.to_h { |record| [ record.fetch("ordinal"), record.fetch("input_binding") ] },
          error_code: nil
        )
      end

      result = current_projection(root, observer: observer).call

      assert_equal 1, calls
      assert_equal "Suggested answer", result.dig(1, "text")
      assert_equal "Because the tracked contract says so.", result.dig(1, "rationale")
      assert_equal [ "repository" ], result.dig(1, "provenance")
      assert_nil result.dig(2, "text")
      assert_equal "failed", result.dig(2, "state")
      assert_equal true, result.dig(2, "retryable")
    end
  end

  def test_changed_binding_synchronously_hides_candidate_text
    with_task do |root|
      record = fresh_record(1)
      write_document(root, [ record ])
      observer = lambda do |**|
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: { 1 => "f" * 64 }, error_code: nil
        )
      end

      suggestion = current_projection(root, questions: questions.first(1), observer: observer).call.fetch(1)

      assert_equal "stale", suggestion.fetch("state")
      assert_nil suggestion.fetch("text")
      assert_nil suggestion.fetch("rationale")
      assert_empty suggestion.fetch("provenance")
      assert_equal Hive::BrainstormSuggestions::Projection::STALE_REASON,
                   suggestion.fetch("safe_reason")
    end
  end

  def test_observation_failure_hides_every_actionable_candidate
    with_task do |root|
      write_document(root, [ fresh_record(1), fresh_record(2) ])
      observer = lambda do |**|
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: {}, error_code: "capture_timeout"
        )
      end

      result = current_projection(root, observer: observer).call

      assert_equal %w[unavailable unavailable], result.values.map { |item| item.fetch("state") }
      assert result.values.all? { |item| item["text"].nil? && item["retryable"] == true }
    end
  end

  def test_explicit_identity_cache_is_shared_across_consumers_and_invalidates
    with_task do |root|
      write_document(root, [ fresh_record(1) ])
      calls = 0
      observer = lambda do |records:, **|
        calls += 1
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: { 1 => records.first.fetch("input_binding") }, error_code: nil
        )
      end
      identity = "epoch-one"
      factory = ->(*) { identity }
      cache = Hive::BrainstormSuggestions::Projection::Cache.new

      2.times do
        current_projection(
          root, questions: questions.first(1), observer: observer,
          identity_factory: factory, cache: cache
        ).call
      end
      assert_equal 1, calls

      identity = "epoch-two"
      current_projection(
        root, questions: questions.first(1), observer: observer,
        identity_factory: factory, cache: cache
      ).call
      assert_equal 2, calls
    end
  end

  def test_cache_coalesces_concurrent_consumers
    cache = Hive::BrainstormSuggestions::Projection::Cache.new
    started = Queue.new
    release = Queue.new
    calls = 0
    operation = lambda do
      cache.fetch("same-task-epoch") do
        calls += 1
        started << true
        release.pop
        :observed
      end
    end

    first = Thread.new(&operation)
    started.pop
    second = Thread.new(&operation)
    Timeout.timeout(1) { Thread.pass until second.status == "sleep" }
    release << true

    assert_equal :observed, first.value
    assert_equal :observed, second.value
    assert_equal 1, calls
  ensure
    first&.kill
    second&.kill
  end

  def test_default_observer_and_explicit_worktree_identity_invalidate_changed_content
    with_task do |root|
      source = File.join(root, "adapter.rb")
      File.write(source, "class Adapter; end\n")
      system("git", "init", "-q", root, exception: true)
      system("git", "-C", root, "config", "user.email", "test@example.com", exception: true)
      system("git", "-C", root, "config", "user.name", "Hive Test", exception: true)
      system("git", "-C", root, "add", "adapter.rb", exception: true)
      system("git", "-C", root, "commit", "-qm", "initial", exception: true)
      bundle = Hive::BrainstormSuggestions::ContextBundle.capture(
        project_root: root, task_root: root, question_ordinal: 1
      )
      record = fresh_record(1)
      binding = Hive::BrainstormSuggestions::Binding.input(
        task_incarnation: "incarnation", task_generation: 0,
        brainstorm_generation: "b" * 64, question_identity: record.fetch("question_id"),
        question_text: "First?", manifest: bundle.manifest,
        settled_answers: bundle.settled_answers
      )
      record["input_binding"] = binding
      record["input_epoch"] = binding
      write_document(root, [ record ])
      cache = Hive::BrainstormSuggestions::Projection::Cache.new

      first = default_projection(root, cache: cache).call.fetch(1)
      File.write(source, "class Adapter; def changed = true; end; end\n")
      second = default_projection(root, cache: cache).call.fetch(1)

      assert_equal "fresh", first.fetch("state")
      assert_equal "Suggested answer", first.fetch("text")
      assert_equal "stale", second.fetch("state")
      assert_nil second.fetch("text")
    end
  end

  def test_task_generation_mismatch_is_stale_without_an_observation
    with_task do |root|
      write_document(root, [ fresh_record(1) ])
      projection = build_projection(root, questions: questions.first(1), observer: ->(**) { flunk })
      projection.define_singleton_method(:current_task_generation) { 99 }

      suggestion = projection.call.fetch(1)

      assert_equal "stale", suggestion.fetch("state")
      assert_nil suggestion.fetch("text")
    end
  end

  def test_corrupt_store_fails_closed
    with_task do |root|
      path = File.join(root, Hive::BrainstormSuggestions::Store::FILENAME)
      File.write(path, "{not-json")
      File.chmod(0o600, path)

      suggestion = build_projection(root, questions: questions.first(1)).call.fetch(1)

      assert_equal "unavailable", suggestion.fetch("state")
      assert_nil suggestion.fetch("text")
    end
  end

  private

  def with_task
    Dir.mktmpdir("suggestion-projection") do |root|
      File.write(File.join(root, "idea.md"), "# Request\n")
      File.write(
        File.join(root, "brainstorm.md"),
        "### Q1. First?\n### A1.\n### Q2. Second?\n### A2.\n"
      )
      yield root
    end
  end

  def questions
    [ Question.new(text: "First?", answer: nil), Question.new(text: "Second?", answer: nil) ]
  end

  def current_projection(root, **options)
    projection = build_projection(root, **options)
    projection.define_singleton_method(:document_current?) { |_document| true }
    projection
  end

  def default_projection(root, cache:)
    Hive::BrainstormSuggestions::Projection.new(
      task_root: root,
      project_root: root,
      questions: questions.first(1),
      task_generation: "a" * 64,
      cache: cache
    ).tap do |projection|
      projection.define_singleton_method(:document_current?) { |_document| true }
    end
  end

  def build_projection(root, questions: self.questions, observer: nil, identity_factory: nil,
                       cache: Hive::BrainstormSuggestions::Projection::Cache.new)
    Hive::BrainstormSuggestions::Projection.new(
      task_root: root,
      project_root: root,
      questions: questions,
      task_generation: "a" * 64,
      observer: observer,
      cache: cache,
      identity_factory: identity_factory || ->(*) { "identity" }
    )
  end

  def write_document(root, records)
    Hive::BrainstormSuggestions::Store.new(root).write(
      "task_incarnation" => "incarnation",
      "task_generation" => 0,
      "brainstorm_generation" => "b" * 64,
      "recipe_version" => Hive::BrainstormSuggestions::ContextBundle::RECIPE_VERSION,
      "records" => records,
      "updated_at" => "2026-08-30T12:00:00.000000Z"
    )
  end

  def fresh_record(ordinal)
    common_record(ordinal).merge(
      "suggestion_binding" => (ordinal + 2).to_s * 64,
      "state" => "fresh",
      "text" => "Suggested answer",
      "rationale" => "Because the tracked contract says so.",
      "provenance" => [ "repository" ],
      "safe_reason" => nil,
      "retryable" => false,
      "candidate_id" => "candidate-#{ordinal}"
    )
  end

  def failed_record(ordinal)
    common_record(ordinal).merge(
      "state" => "failed",
      "safe_reason" => "The provider did not return a safe suggestion.",
      "retryable" => true,
      "error_code" => "provider_failed"
    )
  end

  def common_record(ordinal)
    question = questions.fetch(ordinal - 1)
    binding = ordinal.to_s * 64
    {
      "question_id" => "question-#{ordinal}",
      "ordinal" => ordinal,
      "round" => 1,
      "question_number" => ordinal,
      "question_fingerprint" => Hive::BrainstormParser.question_fingerprint(question.text),
      "input_binding" => binding,
      "input_epoch" => binding,
      "suggestion_binding" => nil,
      "state" => "loading",
      "text" => nil,
      "rationale" => nil,
      "provenance" => [],
      "safe_reason" => nil,
      "retryable" => false,
      "dismissed" => false,
      "attempt_id" => "attempt-#{ordinal}",
      "candidate_id" => nil,
      "requested_at" => "2026-08-30T12:00:00.000000Z",
      "updated_at" => "2026-08-30T12:00:00.000000Z",
      "next_retry_at" => nil,
      "automatic_attempts" => 1,
      "error_code" => nil
    }
  end
end
