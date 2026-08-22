require "test_helper"
require "json"
require "hive/commands/refactor_patrol_classify"

class HiveCommandsRefactorPatrolClassifyTest < Minitest::Test
  include HiveTestHelper

  OCCURRENCE_ID = "a" * 64
  RESERVATION_ID = "b" * 64

  class Classifier
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def run_occurrence(occurrence_id, reservation_id:)
      @calls << [ occurrence_id, reservation_id ]
      raise @error if @error

      { "occurrence_id" => occurrence_id, "status" => "feature" }
    end
  end

  def test_runs_the_reserved_occurrence_and_persists_the_completion_envelope
    with_project do |entry, result_path|
      classifier = Classifier.new
      command = build_command(
        result_path, classifier_factory: ->(_entry, _cfg) { classifier }
      )

      out, = capture_io { assert command.call }
      payload = JSON.parse(out)

      assert_equal [ [ OCCURRENCE_ID, RESERVATION_ID ] ], classifier.calls
      assert_equal payload, JSON.parse(File.read(result_path))
      assert_equal "feature", payload.fetch("status")
      assert_equal 0o600, File.stat(result_path).mode & 0o777
    end
  end

  def test_failure_after_path_validation_persists_a_bounded_failure_envelope
    with_project do |_entry, result_path|
      classifier = Classifier.new(error: RuntimeError.new("provider token=secret failed"))
      command = build_command(
        result_path, classifier_factory: ->(_entry, _cfg) { classifier }
      )

      out, = capture_io do
        error = assert_raises(RuntimeError) { command.call }
        assert_equal "provider token=secret failed", error.message
      end
      payload = JSON.parse(out)

      refute payload.fetch("ok")
      assert_equal payload, JSON.parse(File.read(result_path))
      assert_operator payload.fetch("error").bytesize, :<=, 2_000
    end
  end

  def test_unknown_project_emits_failure_without_attempting_a_result_write
    with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { nil }) do
      command = build_command("/not/validated.json", classifier_factory: ->(*) { flunk })

      out, = capture_io do
        assert_raises(Hive::ConfigError) { command.call }
      end

      refute JSON.parse(out).fetch("ok")
    end
  end

  def test_result_identity_and_fenced_path_are_strict
    with_project do |entry, result_path|
      invalid = [
        [ "bad", RESERVATION_ID, result_path ],
        [ OCCURRENCE_ID, "bad", result_path ],
        [ OCCURRENCE_ID, RESERVATION_ID, File.join(entry.fetch("path"), "outside.json") ]
      ]

      invalid.each do |occurrence_id, reservation_id, path|
        command = Hive::Commands::RefactorPatrolClassify.new(
          "demo", occurrence_id: occurrence_id, reservation_id: reservation_id,
          result_file: path, classifier_factory: ->(*) { flunk }, config_loader: ->(*) { {} }
        )
        capture_io { assert_raises(Hive::ConfigError) { command.call } }
      end
    end
  end

  def test_original_error_survives_failure_envelope_write_failure
    with_project do |_entry, result_path|
      command = build_command(
        result_path,
        classifier_factory: ->(*) { Classifier.new(error: RuntimeError.new("classifier failed")) }
      )
      replacement = ->(*) { raise IOError, "disk unavailable" }

      with_replaced_singleton_method(Hive::AtomicFile, :write, replacement) do
        capture_io do
          error = assert_raises(RuntimeError) { command.call }
          assert_equal "classifier failed", error.message
        end
      end
    end
  end

  def test_default_classifier_uses_the_registered_state_root
    with_project do |entry, result_path|
      command = build_command(result_path)

      classifier = command.send(
        :classifier_for, entry, entry.fetch("path"),
        { "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" } }
      )

      assert_instance_of Hive::RefactorPatrol::MergeClassifier, classifier
    end
  end

  def test_default_config_loader_is_retained
    command = Hive::Commands::RefactorPatrolClassify.new(
      "demo", occurrence_id: OCCURRENCE_ID, reservation_id: RESERVATION_ID,
      result_file: "/tmp/not-used", classifier_factory: ->(*) { flunk }
    )

    loader = command.instance_variable_get(:@config_loader)
    assert_respond_to loader, :call
    with_replaced_singleton_method(Hive::Config, :load, ->(path) { { "path" => path } }) do
      assert_equal({ "path" => "/tmp/project" }, loader.call("/tmp/project"))
    end
  end

  private

  def with_project
    Dir.mktmpdir("refactor-patrol-classify") do |dir|
      state = File.join(dir, ".hive-state")
      result_root = File.join(state, "refactor_patrol", "v2", "results")
      FileUtils.mkdir_p(result_root)
      entry = { "name" => "demo", "path" => dir, "hive_state_path" => state }
      result_path = File.join(result_root, "classification-#{OCCURRENCE_ID}-token.json")
      with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { entry }) do
        yield entry, result_path
      end
    end
  end

  def build_command(result_path, classifier_factory: nil)
    Hive::Commands::RefactorPatrolClassify.new(
      "demo", occurrence_id: OCCURRENCE_ID, reservation_id: RESERVATION_ID,
      result_file: result_path, classifier_factory: classifier_factory,
      config_loader: ->(_path) { {} }
    )
  end
end
