require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/approve"
require "hive/commands/init"
require "hive/commands/new"
# Load the sibling command with the same lexical constant name before task
# fingerprinting, matching the full-suite command load order.
require "hive/commands/digest"
require "hive/task_meta"

class NewIdempotencyTest < Minitest::Test
  include HiveTestHelper

  def test_retry_returns_original_task_after_it_moves
    with_initialized_project do |project_root, project|
      first = create_json(
        project, "draft launch post", key: "workflow-creator:editorial:v1", slug: "editorial-task"
      )
      assert_equal true, first.fetch("created")
      folder = File.join(project_root, ".hive-state", "stages", "1-inbox", "editorial-task")
      Hive::Commands::Approve.new(
        folder, to: "2-brainstorm", from: "1-inbox", force: true, quiet: true
      ).call

      retry_payload = create_json(
        project, "draft launch post", key: "workflow-creator:editorial:v1", slug: "editorial-task"
      )

      assert_equal false, retry_payload.fetch("created")
      assert_equal "editorial-task", retry_payload.fetch("slug")
      assert_equal "2-brainstorm", retry_payload.fetch("current_stage")
      assert_equal 1, idempotent_tasks(project_root).size
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-new"))))
      assert_empty schemer.validate(retry_payload).to_a
    end
  end

  def test_reusing_key_for_different_input_is_rejected_without_a_second_task
    with_initialized_project do |project_root, project|
      create_json(project, "first request", key: "creator:stable", slug: "first-task")

      error = assert_raises(Hive::Commands::New::IdempotencyConflict) do
        Hive::Commands::New.new(
          project, "different request", slug_override: "second-task",
          idempotency_key: "creator:stable", json: true
        ).call!
      end

      assert_includes error.message, "different input or workflow"
      assert_equal 1, idempotent_tasks(project_root).size

      out, err, status = with_captured_exit do
        Hive::Commands::New.new(
          project, "different request", slug_override: "second-task",
          idempotency_key: "creator:stable", json: true
        ).call
      end
      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty err
      assert_equal "usage", payload.fetch("error_kind")
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-new"))))
      assert_empty schemer.validate(payload).to_a
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_legacy_creation_does_not_write_idempotency_metadata
    with_initialized_project do |project_root, project|
      capture_io { Hive::Commands::New.new(project, "ordinary task", slug_override: "ordinary-task").call! }
      folder = File.join(project_root, ".hive-state", "stages", "1-inbox", "ordinary-task")
      metadata = File.read(File.join(folder, "meta.yml"))

      refute_includes metadata, "idempotency_key"
      refute_includes metadata, "input_fingerprint"
    end
  end

  private

  def with_initialized_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io do
          Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call
        end
        yield project_root, File.basename(project_root)
      end
    end
  end

  def create_json(project, text, key:, slug:)
    out, err = capture_io do
      Hive::Commands::New.new(
        project, text, slug_override: slug, idempotency_key: key, json: true
      ).call!
    end
    assert_empty err
    JSON.parse(out)
  end

  def idempotent_tasks(project_root)
    Dir.glob(File.join(project_root, ".hive-state", "stages", "*", "*", "meta.yml")).select do |path|
      Hive::TaskMeta.read(File.dirname(path))[:idempotency_key]
    end
  end
end
