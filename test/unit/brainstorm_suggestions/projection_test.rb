require "test_helper"
require "hive/brainstorm_suggestions/projection"

class HiveBrainstormSuggestionsProjectionTest < Minitest::Test
  include HiveTestHelper

  Question = Data.define(:text, :answer) do
    def answered? = !answer.nil?
  end
  FIXTURE_IDENTITY_FACTORY = lambda do |document, records, _deadline|
    Hive::BrainstormSuggestions::Binding.digest(
      "generation" => document.slice(
        "task_incarnation", "task_generation", "brainstorm_generation", "recipe_version"
      ),
      "records" => records
    )
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

  def test_disabled_projection_emits_no_advisory_slots
    with_task do |root|
      FileUtils.mkdir_p(File.join(root, ".hive-state"))
      File.write(
        File.join(root, ".hive-state", "config.yml"),
        { "brainstorm" => { "suggestions" => { "enabled" => false } } }.to_yaml
      )
      projection = build_projection(
        root, enabled: nil, observer: ->(**) { flunk "disabled projection must not observe" }
      )

      assert_empty projection.call
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

  def test_failed_observation_is_not_cached
    with_task do |root|
      write_document(root, [ fresh_record(1) ])
      calls = 0
      observer = lambda do |records:, **|
        calls += 1
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: calls == 1 ? {} : { 1 => records.first.fetch("input_binding") },
          error_code: calls == 1 ? "capture_timeout" : nil
        )
      end
      cache = Hive::BrainstormSuggestions::Projection::Cache.new

      first = current_projection(
        root, questions: questions.first(1), observer: observer, cache: cache
      ).call.fetch(1)
      second = current_projection(
        root, questions: questions.first(1), observer: observer, cache: cache
      ).call.fetch(1)

      assert_equal "unavailable", first.fetch("state")
      assert_equal "fresh", second.fetch("state")
      assert_equal 2, calls
    end
  end


  def test_fresh_record_without_a_complete_input_epoch_never_exposes_text
    with_task do |root|
      record = fresh_record(1)
      record["input_epoch"] = nil
      write_document(root, [ record ])

      suggestion = current_projection(root, questions: questions.first(1)).call.fetch(1)

      assert_equal "unavailable", suggestion.fetch("state")
      assert_nil suggestion.fetch("text")
      assert suggestion.frozen?
    end
  end

  def test_dismissed_fresh_record_hides_payload_server_side
    with_task do |root|
      record = fresh_record(1).merge("dismissed" => true)
      write_document(root, [ record ])
      observer = lambda do |records:, **|
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: { 1 => records.first.fetch("input_binding") }, error_code: nil
        )
      end

      suggestion = current_projection(
        root, questions: questions.first(1), observer: observer
      ).call.fetch(1)

      assert_nil suggestion.fetch("text")
      assert_nil suggestion.fetch("rationale")
      assert_empty suggestion.fetch("provenance")
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

  def test_warm_cache_is_rechecked_before_exposing_text
    with_task do |root|
      write_document(root, [ fresh_record(1) ])
      calls = 0
      identities = %w[a a a b]
      observer = lambda do |records:, **|
        calls += 1
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: { 1 => records.first.fetch("input_binding") }, error_code: nil
        )
      end
      cache = Hive::BrainstormSuggestions::Projection::Cache.new
      build = lambda do
        current_projection(
          root, questions: questions.first(1), observer: observer, cache: cache,
          identity_factory: ->(*) { identities.shift || flunk("unexpected identity probe") }
        )
      end

      assert_equal "fresh", build.call.call.dig(1, "state")
      raced = build.call.call.fetch(1)

      assert_equal 1, calls
      assert_equal "stale", raced.fetch("state")
      assert_nil raced.fetch("text")
    end
  end

  def test_drift_during_a_cache_miss_is_not_cached
    with_task do |root|
      write_document(root, [ fresh_record(1) ])
      calls = 0
      identities = %w[a b a a]
      observer = lambda do |records:, **|
        calls += 1
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: { 1 => records.first.fetch("input_binding") }, error_code: nil
        )
      end
      cache = Hive::BrainstormSuggestions::Projection::Cache.new
      build = lambda do
        current_projection(
          root, questions: questions.first(1), observer: observer, cache: cache,
          identity_factory: ->(*) { identities.shift || flunk("unexpected identity probe") }
        )
      end

      assert_equal "stale", build.call.call.dig(1, "state")
      assert_equal "fresh", build.call.call.dig(1, "state")
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

  def test_candidate_state_change_invalidates_the_read_cache
    with_task do |root|
      failed = failed_record(1)
      write_document(root, [ failed ])
      calls = 0
      observer = lambda do |records:, **|
        calls += 1
        Hive::BrainstormSuggestions::Projection::Observation.new(
          bindings: { 1 => records.first.fetch("input_binding") }, error_code: nil
        )
      end
      cache = Hive::BrainstormSuggestions::Projection::Cache.new

      first = current_projection(
        root, questions: questions.first(1), observer: observer, cache: cache
      ).call.fetch(1)
      fresh = fresh_record(1)
      fresh["input_binding"] = failed.fetch("input_binding")
      fresh["input_epoch"] = failed.fetch("input_epoch")
      write_document(root, [ fresh ])
      second = current_projection(
        root, questions: questions.first(1), observer: observer, cache: cache
      ).call.fetch(1)

      assert_equal "failed", first.fetch("state")
      assert_equal "fresh", second.fetch("state")
      assert_equal 2, calls
    end
  end

  def test_default_identity_hides_cached_text_immediately_after_a_tracked_edit
    with_task do |root|
      source = File.join(root, "adapter.rb")
      File.write(source, "class Adapter; end\n")
      initialize_repository(root, "adapter.rb")
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
      unchanged = default_projection(root, cache: cache).call.fetch(1)
      File.write(source, "class Adapter; def changed = true; end; end\n")
      changed = default_projection(root, cache: cache).call.fetch(1)

      assert_equal "fresh", first.fetch("state")
      assert_equal "Suggested answer", unchanged.fetch("text")
      assert_equal "stale", changed.fetch("state")
      assert_nil changed.fetch("text")
      assert_nil changed.fetch("rationale")
      assert_empty changed.fetch("provenance")
    end
  end

  def test_external_identity_ignores_untracked_files_and_head_only_commits
    with_task do |root|
      File.write(File.join(root, "adapter.rb"), "class Adapter; end\n")
      initialize_repository(root, "adapter.rb")
      projection = build_projection(root, identity_factory: nil)
      document = { "task_incarnation" => "incarnation" }
      records = [ fresh_record(1) ]
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      original = projection.send(:observation_identity, document, records, deadline)

      File.write(File.join(root, "untracked.tmp"), "ignored input\n")
      git(root, "commit", "--allow-empty", "-qm", "empty")
      current = projection.send(
        :observation_identity, document, records,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      )

      assert_equal original, current
    end
  end

  def test_main_wiki_identity_is_tracked_only_and_invalidates_on_tracked_edits
    with_task do |root|
      wiki = File.join(root, "shared-wiki")
      FileUtils.mkdir_p([ File.join(root, ".llm-wiki"), wiki ])
      File.write(File.join(root, ".llm-wiki", "config.json"), JSON.generate("main_wiki_path" => "shared-wiki"))
      File.write(File.join(wiki, "adapter.md"), "adapter evidence\n")
      initialize_repository(wiki, "adapter.md")
      projection = build_projection(root, identity_factory: nil)
      identity = -> {
        projection.send(
          :main_wiki_identity, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        )
      }

      original = identity.call
      File.write(File.join(wiki, "untracked.md"), "not eligible\n")
      assert_equal original, identity.call

      File.write(File.join(wiki, "adapter.md"), "changed adapter evidence\n")
      refute_equal original, identity.call
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

  def test_cache_releases_waiters_when_the_owner_raises
    cache = Hive::BrainstormSuggestions::Projection::Cache.new(limit: 1)

    assert_raises(IOError) { cache.fetch("identity") { raise IOError, "capture failed" } }
    assert_equal "recovered", cache.fetch("identity") { "recovered" }
    assert_equal "other", cache.fetch("other") { "other" }
  end

  def test_observer_maps_capture_and_shape_errors_to_bounded_codes
    document = {
      "task_incarnation" => "task", "task_generation" => 1,
      "brainstorm_generation" => "b" * 64
    }
    records = [ fresh_record(1) ]

    observer = Hive::BrainstormSuggestions::Projection::Observer.new(
      context_factory: ->(**) {
        raise Hive::BrainstormSuggestions::ContextBundle::CaptureError.new("capture_timeout")
      }
    )
    captured = observer.call(
      project_root: "/tmp", task_root: "/tmp", questions: questions,
      records: records, document: document, deadline: Float::INFINITY
    )
    assert_equal "capture_timeout", captured.error_code

    observer = Hive::BrainstormSuggestions::Projection::Observer.new(
      context_factory: ->(**) { raise ArgumentError, "bad bundle" }
    )
    unavailable = observer.call(
      project_root: "/tmp", task_root: "/tmp", questions: questions,
      records: records, document: document, deadline: Float::INFINITY
    )
    assert_equal "observation_unavailable", unavailable.error_code
  end

  def test_projection_and_task_generation_errors_hide_all_candidates
    with_task do |root|
      write_document(root, [ fresh_record(1) ])
      projection = build_projection(
        root,
        questions: questions.first(1),
        identity_factory: ->(*) { raise IOError, "identity unavailable" }
      )
      projection.define_singleton_method(:document_current?) { |_document| true }

      assert_equal "unavailable", projection.call.dig(1, "state")

      with_replaced_singleton_method(
        Hive::Attempts::Generation, :current_task_input_epoch,
        ->(*) { raise Hive::Error, "generation unavailable" }
      ) do
        assert_nil projection.send(:current_task_generation)
      end
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
      enabled: true,
      cache: cache
    ).tap do |projection|
      projection.define_singleton_method(:document_current?) { |_document| true }
    end
  end

  def build_projection(root, questions: self.questions, observer: nil, identity_factory: nil,
                       enabled: true,
                       cache: Hive::BrainstormSuggestions::Projection::Cache.new)
    arguments = {
      task_root: root,
      project_root: root,
      questions: questions,
      task_generation: "a" * 64,
      enabled: enabled,
      observer: observer,
      cache: cache
    }
    arguments[:identity_factory] = identity_factory || FIXTURE_IDENTITY_FACTORY
    Hive::BrainstormSuggestions::Projection.new(**arguments)
  end

  def initialize_repository(root, *paths)
    git(root, "init", "-q")
    git(root, "config", "user.email", "test@example.com")
    git(root, "config", "user.name", "Hive Test")
    git(root, "add", *paths)
    git(root, "commit", "-qm", "initial")
  end

  def git(root, *arguments)
    system("git", "-C", root, *arguments, exception: true)
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
