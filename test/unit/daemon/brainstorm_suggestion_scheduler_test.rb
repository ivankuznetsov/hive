# frozen_string_literal: true

require "test_helper"
require "hive/daemon/brainstorm_suggestion_scheduler"
require "hive/daemon/status_consumer"

class BrainstormSuggestionSchedulerTest < Minitest::Test
  include HiveTestHelper

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

  private

  def with_project
    with_tmp_global_config do
      with_tmp_dir do |root|
        project = File.join(root, "demo")
        state = File.join(project, ".hive-state")
        folder = File.join(state, "stages", "2-brainstorm", "suggestions-260830-abcd")
        FileUtils.mkdir_p(folder)
        File.write(File.join(state, "config.yml"), {}.to_yaml)
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

  def scheduler_for(runner, digest, cfg: suggestion_config)
    context_factory = lambda do |**_kwargs|
      FakeBundle.new(
        manifest: {
          "recipe" => "tracked-relevance",
          "recipe_version" => 1,
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
    Hive::Daemon::BrainstormSuggestionScheduler.new(
      context_factory: context_factory,
      runner_factory: ->(_config, _project_root) { runner },
      config_loader: ->(_project_root) { cfg },
      worker_launcher: ->(work) { work.call },
      clock: -> { fixture_time },
      max_workers: 2
    )
  end

  def suggestion_config
    Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
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
