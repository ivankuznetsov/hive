require "test_helper"
require "hive/stages/artifacts"
require "hive/task"

class StagesArtifactsPromptTest < Minitest::Test
  def test_legacy_prompt_has_no_completion_authority
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)

      prompt = Hive::Stages::Artifacts.render_prompt(task)

      assert_includes prompt, "controller-owned"
      assert_includes prompt, "fresh"
      assert_includes prompt, "agent-authored `<!-- COMPLETE -->` marker"
    end
  end

  def test_render_prompt_cannot_turn_connected_screenote_into_ambient_upload_authority
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = task_for(dir)

      prompt = Hive::Stages::Artifacts.render_prompt(
        task,
        screenote: {
          connected: true,
          project_id: "proj_123",
          base_url: "https://screenote.test",
          reason: nil
        }
      )

      assert_includes prompt, "controller-owned"
      refute_includes prompt, "proj_123"
      refute_includes prompt, "https://screenote.test"
      refute_includes prompt, "signed upload URL"
    end
  end

  def test_render_prompt_does_not_leak_disconnected_screenote_configuration
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = task_for(dir)
      reason = "Screenote OAuth token expired; run `hive connect screenote`."

      prompt = Hive::Stages::Artifacts.render_prompt(
        task,
        screenote: {
          connected: false,
          project_id: nil,
          base_url: "https://screenote.test",
          reason: reason
        }
      )

      assert_includes prompt, "controller-owned"
      refute_includes prompt, reason
      refute_includes prompt, "https://screenote.test"
    end
  end

  def test_role_prompts_separate_inference_production_and_independent_temporal_review
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = task_for(dir)
      inference = Hive::Stages::Artifacts.render_role_prompt(
        "artifacts_inference_prompt.md.erb", task, identity_json: "{}"
      )
      producer = Hive::Stages::Artifacts.render_role_prompt(
        "artifacts_producer_prompt.md.erb", task,
        requirement_json: "{}", prior_evidence_json: "[]", revision_json: "[]",
        writable_root: File.join(task.folder, "evidence")
      )
      reviewer = Hive::Stages::Artifacts.render_role_prompt(
        "artifacts_reviewer_prompt.md.erb", task,
        requirement_json: "{}", evidence_json: "[]"
      )

      assert_includes inference, "fresh read-only context"
      assert_includes inference, "not one claim per file"
      assert_includes producer, "evidence-write root"
      assert_includes producer, "preserves accepted prior artifacts"
      assert_match(/Never edit\s+the worktree/, producer)
      assert_includes reviewer, "third fresh"
      assert_includes reviewer, "actual temporal video"
      assert_includes reviewer, "every representation SHA-256"
      assert_includes reviewer, "accepted`, `revise`, or `blocked"
      [ inference, producer, reviewer ].each { |prompt| assert_includes prompt, "untrusted data" }
    end
  end

  private

  def task_for(dir)
    folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end
end
