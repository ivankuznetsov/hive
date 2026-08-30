# frozen_string_literal: true

require "test_helper"
require "hive/bot/brainstorm_answer_writer"
require "hive/daemon/brainstorm_suggestion_scheduler"
require "hive/daemon/status_consumer"

class BrainstormSuggestionSchedulerTest < Minitest::Test
  include HiveTestHelper

  class EventLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **payload)
      @events << [ name, payload ]
    end
  end

  FakeBundle = Struct.new(:manifest, :settled_answers, keyword_init: true)

  class FakeRunner
    attr_reader :calls

    def initialize(result: nil, &before_result)
      @result = result || {
        "state" => "fresh",
        "text" => "Use the repository's existing scheduler seam.",
        "rationale" => "It already owns daemon polling.",
        "provenance" => %w[repository request],
        "safe_reason" => nil,
        "retryable" => true,
        "dismissed" => false
      }
      @before_result = before_result
      @calls = 0
    end

    def call(bundle:, cancellation:)
      @calls += 1
      @before_result&.call(bundle, cancellation)
      @result
    end
  end

  class UnavailableRunner
    def available? = false
  end

  def test_missing_record_is_reconciled_and_an_unchanged_fresh_candidate_is_idempotent
    with_project do |_project, folder|
      digest = "a" * 64
      runner = FakeRunner.new
      scheduler = scheduler_for(runner, -> { digest })

      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      record = record_for(folder)

      assert_equal "fresh", record.fetch("state")
      assert_equal "Use the repository's existing scheduler seam.", record.fetch("text")
      assert_equal %w[repository request], record.fetch("provenance")
      assert_match(/\A[0-9a-f]{64}\z/, record.fetch("input_binding"))
      assert_match(/\A[0-9a-f]{64}\z/, record.fetch("suggestion_binding"))
      assert_equal 1, runner.calls

      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 1)
      assert_equal 1, runner.calls
    ensure
      scheduler&.shutdown
    end
  end

  def test_selected_manifest_change_starts_a_new_input_epoch_without_head_identity
    with_project do |_project, folder|
      digest = "a" * 64
      runner = FakeRunner.new
      scheduler = scheduler_for(runner, -> { digest })
      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      first = record_for(folder).fetch("input_binding")

      digest = "b" * 64
      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 10)
      assert_equal first, record_for(folder).fetch("input_binding")
      assert_equal 1, runner.calls

      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 301)
      second = record_for(folder)

      refute_equal first, second.fetch("input_binding")
      assert_equal "fresh", second.fetch("state")
      assert_equal 1, second.fetch("automatic_attempts")
      assert_equal 2, runner.calls
    ensure
      scheduler&.shutdown
    end
  end

  def test_answer_won_during_generation_fences_the_late_result_and_next_tick_cleans_state
    with_project do |_project, folder|
      brainstorm = File.join(folder, "brainstorm.md")
      runner = FakeRunner.new do
        File.write(brainstorm, File.read(brainstorm).sub("### A1.\n", "### A1.\nOperator answer\n"))
      end
      scheduler = scheduler_for(runner, -> { "a" * 64 })

      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      refute_equal "fresh", record_for(folder).fetch("state")

      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 1)
      refute File.exist?(File.join(folder, Hive::BrainstormSuggestions::STORE_FILENAME))
      assert_equal "Operator answer", Hive::BrainstormParser.parse(brainstorm).first.answer
    ensure
      scheduler&.shutdown
    end
  end

  def test_leaving_brainstorm_removes_sidecar_and_projection_envelope
    with_project do |project, folder|
      runner = FakeRunner.new
      scheduler = scheduler_for(runner, -> { "a" * 64 })
      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      record = record_for(folder)
      path = File.join(folder, "brainstorm.md")
      body = File.read(path).sub(
        "### A1.\n",
        "### A1.\n#{Hive::BrainstormSuggestions::Envelope.render(binding: record.fetch('suggestion_binding'), text: record.fetch('text'))}"
      )
      File.write(path, body)

      destination = File.join(project, ".hive-state", "stages", "3-plan", File.basename(folder))
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(folder, destination)
      later = row(destination)
      later.stage = "3-plan"
      scheduler.tick(rows: [ later ], now: fixture_time + 1)

      refute File.exist?(File.join(destination, Hive::BrainstormSuggestions::STORE_FILENAME))
      refute_includes File.read(File.join(destination, "brainstorm.md")), "hive-suggestion:v1"
    ensure
      scheduler&.shutdown
    end
  end

  def test_automatic_attempt_budget_is_bounded_per_input_epoch
    with_project do |_project, folder|
      failure = {
        "state" => "failed", "text" => nil, "rationale" => nil,
        "provenance" => [], "safe_reason" => "Suggestion generation failed.",
        "retryable" => true, "dismissed" => false, "error_code" => "provider_exit"
      }
      runner = FakeRunner.new(result: failure)
      cfg = suggestion_config.merge(
        "brainstorm" => suggestion_config.fetch("brainstorm").merge(
          "suggestions" => suggestion_config.dig("brainstorm", "suggestions").merge(
            "max_automatic_attempts" => 1, "min_retry_interval_sec" => 1
          )
        )
      )
      scheduler = scheduler_for(runner, -> { "a" * 64 }, cfg: cfg)

      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 1_000)

      assert_equal 1, runner.calls
      record = record_for(folder)
      assert_equal "failed", record.fetch("state")
      assert_equal "automatic_attempts_exhausted", record.fetch("error_code")
      assert record.fetch("retryable")
    ensure
      scheduler&.shutdown
    end
  end

  def test_provider_launches_are_coalesced_once_per_task_window
    with_project do |_project, folder|
      File.write(
        File.join(folder, "brainstorm.md"),
        <<~MARKDOWN
          ## Round 1

          ### Q1. Which seam should own polling?
          ### A1.

          ### Q2. Which seam should own retries?
          ### A2.

          <!-- WAITING -->
        MARKDOWN
      )
      runner = FakeRunner.new
      scheduler = scheduler_for(runner, -> { "a" * 64 })

      scheduler.tick(rows: [ row(folder) ], now: fixture_time)

      assert_equal 1, runner.calls
      assert_equal %w[fresh loading],
                   Hive::BrainstormSuggestions::Store.new(folder).read.fetch("records").map { |record| record.fetch("state") }

      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 6)

      assert_equal 2, runner.calls
      assert_equal %w[fresh fresh],
                   Hive::BrainstormSuggestions::Store.new(folder).read.fetch("records").map { |record| record.fetch("state") }
    ensure
      scheduler&.shutdown
    end
  end

  def test_slow_capture_does_not_hold_the_task_lock_and_an_answer_cancels_the_worker
    with_project do |_project, folder|
      started = Queue.new
      release = Queue.new
      context_factory = lambda do |**_kwargs|
        started << true
        release.pop
        bundle_for(-> { "a" * 64 })
      end
      runner = FakeRunner.new
      scheduler = scheduler_for(
        runner, -> { "a" * 64 }, context_factory: context_factory,
        worker_launcher: ->(work) { Thread.new(&work) }
      )

      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      started.pop
      brainstorm = File.join(folder, "brainstorm.md")
      result = Timeout.timeout(1) do
        Hive::Lock.with_task_lock(folder, op: "operator_answer") do
          Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
            brainstorm_path: brainstorm, ordinal: 1, answer_text: "Operator answer"
          )
        end
      end
      assert_equal :written, result

      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 1)
      release << true
      scheduler.shutdown

      assert_equal 0, runner.calls
      assert_equal "Operator answer", Hive::BrainstormParser.parse(brainstorm).first.answer
      refute File.exist?(File.join(folder, Hive::BrainstormSuggestions::STORE_FILENAME))
    ensure
      release << true if release&.empty?
      scheduler&.shutdown
    end
  end

  def test_exhausted_question_does_not_consume_the_task_launch_window
    with_project do |_project, folder|
      File.write(
        File.join(folder, "brainstorm.md"),
        <<~MARKDOWN
          ## Round 1
          ### Q1. Which seam should own polling?
          ### A1.
          ### Q2. Which seam should own retries?
          ### A2.
          <!-- WAITING -->
        MARKDOWN
      )
      failure = {
        "state" => "failed", "text" => nil, "rationale" => nil,
        "provenance" => [], "safe_reason" => "Suggestion generation failed.",
        "retryable" => true, "dismissed" => false, "error_code" => "provider_exit"
      }
      runner = FakeRunner.new(result: failure)
      cfg = suggestion_config.merge(
        "brainstorm" => suggestion_config.fetch("brainstorm").merge(
          "suggestions" => suggestion_config.dig("brainstorm", "suggestions").merge(
            "max_automatic_attempts" => 1, "min_retry_interval_sec" => 1
          )
        )
      )
      scheduler = scheduler_for(runner, -> { "a" * 64 }, cfg: cfg)

      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      scheduler.tick(rows: [ row(folder) ], now: fixture_time + 1_000)

      assert_equal 2, runner.calls
      records = Hive::BrainstormSuggestions::Store.new(folder).read.fetch("records")
      assert_equal "automatic_attempts_exhausted", records.fetch(0).fetch("error_code")
      assert_equal "provider_exit", records.fetch(1).fetch("error_code")
    ensure
      scheduler&.shutdown
    end
  end

  def test_startup_tick_and_row_classification_failures_are_bounded
    logger = EventLogger.new
    scheduler = Hive::Daemon::BrainstormSuggestionScheduler.new(logger: logger)

    with_replaced_singleton_method(
      Hive::BrainstormSuggestions::Runner, :sweep_inactive!, ->(*) { 2 }
    ) do
      assert_equal 2, scheduler.startup!
    end
    assert logger.events.any? { |event, _| event == :brainstorm_suggestion_bundle_sweep }

    bad_row = Object.new
    bad_row.define_singleton_method(:folder) { raise IOError, "bad row" }
    refute scheduler.send(:eligible_row?, bad_row)
    refute scheduler.send(:brainstorm_worker_row?, bad_row)

    bad_rows = Object.new
    bad_rows.define_singleton_method(:to_ary) { raise IOError, "bad inventory" }
    assert_equal 0, scheduler.tick(rows: bad_rows)
    assert logger.events.any? { |event, _| event == :brainstorm_suggestion_scheduler_error }
  ensure
    scheduler&.shutdown
  end

  def test_tick_isolates_an_unexpected_failure_for_one_row
    logger = EventLogger.new
    scheduler = Hive::Daemon::BrainstormSuggestionScheduler.new(logger: logger)
    scheduler.define_singleton_method(:eligible_row?) { |_| false }
    scheduler.define_singleton_method(:brainstorm_worker_row?) do |_row|
      raise RuntimeError, "broken row"
    end

    assert_equal 0, scheduler.tick(rows: [ Object.new ], complete: false)
    event = logger.events.find { |name, _| name == :brainstorm_suggestion_scheduler_error }
    assert_includes event.last.fetch(:error), "broken row"
  ensure
    scheduler&.shutdown
  end

  def test_disabled_and_unavailable_rows_cancel_work_without_exposing_errors
    with_project do |_project, folder|
      logger = EventLogger.new
      disabled = suggestion_config
      disabled["brainstorm"]["suggestions"]["enabled"] = false
      scheduler = Hive::Daemon::BrainstormSuggestionScheduler.new(
        logger: logger, config_loader: ->(*) { disabled }
      )
      assert_equal 0, scheduler.tick(rows: [ row(folder) ], now: fixture_time)

      unavailable = Hive::Daemon::BrainstormSuggestionScheduler.new(
        logger: logger,
        config_loader: ->(*) { raise Hive::ConfigError, "config unavailable" }
      )
      assert_nil unavailable.send(:config_for, row(folder))
      assert logger.events.any? { |event, _| event == :brainstorm_suggestion_unavailable }
    ensure
      scheduler&.shutdown
      unavailable&.shutdown
    end
  end

  def test_reconcile_and_worker_launch_errors_are_logged_and_released
    with_project do |_project, folder|
      logger = EventLogger.new
      current_row = row(folder)
      slot_source = Hive::Daemon::BrainstormSuggestionScheduler.new
      slot = slot_source.send(:inventory_slots, folder).first

      locked = Hive::Daemon::BrainstormSuggestionScheduler.new(logger: logger)
      locked.define_singleton_method(:inventory_slots) do |_root|
        raise Hive::ConcurrentRunError, "busy"
      end
      locked.send(:reconcile_row, current_row, suggestion_config, now: fixture_time)

      unavailable = Hive::Daemon::BrainstormSuggestionScheduler.new(logger: logger)
      unavailable.define_singleton_method(:inventory_slots) do |_root|
        raise Hive::Error, "unavailable"
      end
      unavailable.send(:reconcile_row, current_row, suggestion_config, now: fixture_time)

      worker = Hive::Daemon::BrainstormSuggestionScheduler.new(
        logger: logger, worker_launcher: ->(work) { work.call }
      )
      worker.define_singleton_method(:process_slot) do |*_args, **_kwargs|
        raise IOError, "worker failed"
      end
      assert_nil worker.send(:schedule, current_row, suggestion_config, slot, now: fixture_time)

      launcher = Hive::Daemon::BrainstormSuggestionScheduler.new(
        worker_launcher: ->(*) { raise IOError, "launcher failed" }
      )
      assert_raises(IOError) do
        launcher.send(:schedule, current_row, suggestion_config, slot, now: fixture_time)
      end

      assert logger.events.any? { |event, _| event == :brainstorm_suggestion_deferred }
      assert logger.events.any? { |event, _| event == :brainstorm_suggestion_worker_error }
    ensure
      slot_source&.shutdown
      locked&.shutdown
      unavailable&.shutdown
      worker&.shutdown
      launcher&.shutdown
    end
  end

  def test_changed_post_capture_binding_is_stale_and_coalesced
    with_project do |_project, folder|
      digests = [ "a" * 64, "b" * 64 ]
      context_factory = ->(**) { bundle_for(-> { digests.shift || "b" * 64 }) }
      runner = FakeRunner.new
      scheduler = scheduler_for(
        runner, -> { "unused" }, context_factory: context_factory
      )

      scheduler.tick(rows: [ row(folder) ], now: fixture_time)
      record = record_for(folder)

      assert_equal "stale", record.fetch("state")
      assert_equal "selected_inputs_changed", record.fetch("error_code")
      refute_nil record.fetch("next_retry_at")
    ensure
      scheduler&.shutdown
    end
  end

  def test_capture_failure_is_published_but_late_or_locked_failures_are_discarded
    with_project do |_project, folder|
      error = Hive::BrainstormSuggestions::ContextBundle::CaptureError.new("capture_timeout")
      scheduler = scheduler_for(
        FakeRunner.new, -> { "a" * 64 }, context_factory: ->(**) { raise error }
      )
      current_row = row(folder)
      scheduler.tick(rows: [ current_row ], now: fixture_time)
      record = record_for(folder)
      assert_equal "unavailable", record.fetch("state")
      assert_equal "capture_timeout", record.fetch("error_code")

      slot = scheduler.send(:inventory_slots, folder).first
      path = File.join(folder, "brainstorm.md")
      File.write(path, File.read(path).sub("### A1.\n", "### A1.\nOperator answer\n"))
      assert_nil scheduler.send(
        :publish_capture_failure, current_row, slot, "late", now: fixture_time
      )

      with_replaced_singleton_method(
        Hive::Lock, :with_task_lock,
        ->(*) { raise Hive::ConcurrentRunError, "busy" }
      ) do
        assert_nil scheduler.send(
          :publish_capture_failure, current_row, slot, "busy", now: fixture_time
        )
      end

      token = Hive::BrainstormSuggestions::Runner::Cancellation.new
      scheduler.define_singleton_method(:capture) do |*|
        raise Hive::ConcurrentRunError, "capture lock"
      end
      assert_nil scheduler.send(
        :process_slot, current_row, suggestion_config, slot,
        token: token, now: fixture_time
      )
    ensure
      scheduler&.shutdown
    end
  end

  def test_orphan_retry_backoff_cleanup_and_runtime_helpers_are_bounded
    scheduler = Hive::Daemon::BrainstormSuggestionScheduler.new
    config = suggestion_config
    binding = "a" * 64
    loading = {
      "input_epoch" => binding, "state" => "loading", "attempt_id" => "attempt",
      "requested_at" => fixture_time.iso8601(6), "next_retry_at" => nil
    }
    refute scheduler.send(
      :request_due?, loading, binding, config, now: fixture_time + 1
    )

    retry_at = scheduler.send(
      :next_retry_at,
      { "state" => "failed" },
      { "automatic_attempts" => 1, "attempt_id" => "attempt-1" },
      config,
      now: fixture_time
    )
    assert_operator Time.iso8601(retry_at), :>, fixture_time
    assert_instance_of Hive::BrainstormSuggestions::Runner,
                       scheduler.send(:build_runner, config, "/tmp")
    with_replaced_singleton_method(
      Hive::Task, :new, ->(*) { raise Hive::Error, "missing task" }
    ) do
      assert_equal 0, scheduler.send(:task_generation, "/missing/task")
    end
    assert_nil scheduler.send(:parse_time, "invalid")
    refute scheduler.send(:cleanup_task, "/missing/task")

    with_replaced_singleton_method(File, :file?, ->(*) { true }) do
      with_replaced_singleton_method(File, :read, ->(*) { raise Errno::EIO, "read failed" }) do
        refute scheduler.send(:envelope_present?, "/missing/brainstorm.md")
      end
    end
  ensure
    scheduler&.shutdown
  end

  def test_prune_envelope_and_post_publish_failure_paths_are_bounded
    with_project do |_project, folder|
      scheduler = Hive::Daemon::BrainstormSuggestionScheduler.new
      slot = scheduler.send(:inventory_slots, folder).first
      brainstorm = File.join(folder, "brainstorm.md")

      File.write(
        brainstorm,
        "x" * (Hive::BrainstormSuggestions::Envelope::MAX_SCAN_BYTES + 1)
      )
      assert scheduler.send(:envelope_present?, brainstorm)
      File.write(
        brainstorm,
        "<!-- hive-suggestion:v1 binding=#{'a' * 64} -->\n"
      )
      assert scheduler.send(:envelope_present?, brainstorm)

      with_replaced_singleton_method(
        Hive::Lock, :with_task_lock,
        ->(*) { raise Hive::ConcurrentRunError, "busy" }
      ) do
        assert_nil scheduler.send(:prune_removed_questions, folder, [ slot ])
        assert_nil scheduler.send(
          :invalidate_published_result, row(folder), slot,
          { "attempt_id" => "attempt" }, "a" * 64
        )
      end
    ensure
      scheduler&.shutdown
    end
  end

  def test_unavailable_route_hides_fresh_candidate_payload
    with_project do |_project, folder|
      scheduler = Hive::Daemon::BrainstormSuggestionScheduler.new(
        runner_factory: ->(*) { UnavailableRunner.new },
        config_loader: ->(*) { suggestion_config },
        worker_launcher: ->(work) { work.call },
        clock: -> { fixture_time }
      )
      slot = scheduler.send(:inventory_slots, folder).first
      scheduler.send(:seed_records, row(folder), [ slot ], now: fixture_time)
      store = Hive::BrainstormSuggestions::Store.new(folder)
      store.update do |document|
        document.fetch("records").first.merge!(
          "state" => "fresh", "text" => "secret candidate",
          "rationale" => "secret rationale", "provenance" => [ "repository" ],
          "suggestion_binding" => "b" * 64
        )
        document
      end

      scheduler.send(
        :hide_fresh_when_route_unavailable,
        row(folder), suggestion_config, now: fixture_time
      )

      record = record_for(folder)
      assert_equal "unavailable", record.fetch("state")
      assert_nil record.fetch("text")
      assert_nil record.fetch("rationale")
      assert_empty record.fetch("provenance")
      assert_equal "isolation_unavailable", record.fetch("error_code")
      assert record.fetch("retryable")
    ensure
      scheduler&.shutdown
    end
  end

  private

  def with_project
    with_tmp_global_config do
      with_tmp_dir do |root|
        project = File.join(root, "demo")
        state = File.join(project, ".hive-state")
        folder = File.join(state, "stages", "2-brainstorm", "suggestions-260830-abcd")
        FileUtils.mkdir_p(folder)
        File.write(
          File.join(state, "config.yml"),
          { "brainstorm" => { "suggestions" => { "enabled" => true } } }.to_yaml
        )
        Hive::TaskMeta.write(
          folder, id: 43012, slug: File.basename(folder), display_name: "Suggestions",
          idempotency_key: "suggestions", input_fingerprint: "f" * 64
        )
        File.write(File.join(folder, "idea.md"), "Add repository-aware answer help.\n")
        File.write(
          File.join(folder, "brainstorm.md"),
          "## Round 1\n\n### Q1. Which seam should own polling?\n### A1.\n\n<!-- WAITING -->\n"
        )
        yield project, folder
      end
    end
  end

  def scheduler_for(runner, digest, cfg: suggestion_config, context_factory: nil,
                    worker_launcher: nil)
    context_factory ||= lambda do |**_kwargs|
      bundle_for(digest)
    end
    Hive::Daemon::BrainstormSuggestionScheduler.new(
      context_factory: context_factory,
      runner_factory: ->(_config, _project_root) { runner },
      config_loader: ->(_project_root) { cfg },
      worker_launcher: worker_launcher || ->(work) { work.call },
      clock: -> { fixture_time },
      max_workers: 2
    )
  end

  def bundle_for(digest)
    FakeBundle.new(
        manifest: {
          "recipe" => "tracked-relevance",
          "recipe_version" => Hive::BrainstormSuggestions::ContextBundle::RECIPE_VERSION,
          "entries" => [
            {
              "path" => "lib/hive/daemon/dispatcher.rb", "mode" => "100644",
              "digest" => digest.call, "source" => "repository", "bytes" => 10
            },
            {
              "path" => "task/request.txt", "mode" => "100400",
              "digest" => "c" * 64, "source" => "request", "bytes" => 10
            }
          ]
        },
        settled_answers: []
      )
  end

  def suggestion_config
    Marshal.load(Marshal.dump(Hive::Config::DEFAULTS)).tap do |config|
      config.dig("brainstorm", "suggestions")["enabled"] = true
    end
  end

  def row(folder)
    Hive::Daemon::StatusConsumer::Row.new(
      project: "demo", slug: File.basename(folder), id: 43012,
      stage: "2-brainstorm", workflow: "coding", marker: "waiting",
      marker_attrs: {}, folder: folder, state_file: File.join(folder, "brainstorm.md"),
      action: "needs_input"
    )
  end

  def record_for(folder)
    Hive::BrainstormSuggestions::Store.new(folder).read.fetch("records").first
  end

  def fixture_time
    Time.utc(2026, 8, 30, 12, 0, 0)
  end
end
